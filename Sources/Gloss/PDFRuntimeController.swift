import Foundation
import GlossCore

@MainActor
final class PDFRuntimeController {
    nonisolated static let minimumCompatibleManagedRuntimeVersion =
        BabelDOCRuntimeCompatibility.minimumManagedVersion

    struct PreparedRuntime {
        let launch: BabelDOCRuntimeLaunch
        let layoutServiceBaseURL: URL
        let layoutCacheDirectoryURL: URL?
    }

    enum ManagedRuntimePreparation: Equatable {
        case install
        case installAvailableUpdate
        case startCurrent
        case updateRequired(currentVersion: String)
    }

    private enum ControllerError: LocalizedError {
        case runtimeManagerUnavailable
        case runtimeUnavailable
        case runtimeUpdateRequired(current: String, minimum: String)

        var errorDescription: String? {
            switch self {
            case .runtimeManagerUnavailable:
                "无法初始化 BabelDOC 运行时管理器。"
            case .runtimeUnavailable:
                "没有可用的 BabelDOC 运行时。"
            case .runtimeUpdateRequired(let current, let minimum):
                "当前 BabelDOC 运行时 \(current) 已知不兼容。请联网更新到 \(minimum) 或更高版本后再使用 PDF 翻译。"
            }
        }
    }

    let service: BabelDOCServiceSession

    private let runtimeManager: BabelDOCRuntimeManager?
    private var stateContinuations: [UUID: AsyncStream<PDFRuntimeDashboardState>.Continuation] = [:]
    private var runtimeSnapshot: BabelDOCRuntimeSnapshot?
    private var serviceSnapshot = BabelDOCExecutorServiceSnapshot(
        installed: false,
        lifecycleState: .stopped
    )
    private var runtimeObservationTask: Task<Void, Never>?
    private var serviceObservationTask: Task<Void, Never>?
    private var launchPreparationTask: Task<Void, Never>?
    private var launchPreparationID: UUID?
    private var launchPreparationCompleted = false
    private var launchPreparationError: Error?
    private var backgroundUpdateTask: Task<Void, Never>?
    private var backgroundUpdateID: UUID?
    private var modulePreparationTask: Task<PreparedRuntime, Error>?
    private var modulePreparationID: UUID?
    private var moduleCloseTask: Task<Void, Never>?
    private var moduleCloseID: UUID?
    private var actionTask: Task<Void, Never>?
    private var actionID: UUID?
    private var activeDocumentName: String?

    private(set) var dashboardState: PDFRuntimeDashboardState = .checking {
        didSet {
            guard dashboardState != oldValue else { return }
            for continuation in stateContinuations.values {
                continuation.yield(dashboardState)
            }
        }
    }

    init(
        service: BabelDOCServiceSession = .shared,
        runtimeManager: BabelDOCRuntimeManager? = try? BabelDOCRuntimeManager()
    ) {
        self.service = service
        self.runtimeManager = runtimeManager
        startObserving()
        if runtimeManager == nil {
            dashboardState = .failed(
                message: ControllerError.runtimeManagerUnavailable.localizedDescription,
                installedVersion: nil,
                canRollback: false
            )
        }
    }

    deinit {
        runtimeObservationTask?.cancel()
        serviceObservationTask?.cancel()
        backgroundUpdateTask?.cancel()
        modulePreparationTask?.cancel()
        moduleCloseTask?.cancel()
        actionTask?.cancel()
    }

    func stateChanges() -> AsyncStream<PDFRuntimeDashboardState> {
        let observationID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            stateContinuations[observationID] = continuation
            continuation.yield(dashboardState)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stateContinuations.removeValue(forKey: observationID)
                }
            }
        }
    }

    var currentRuntimeLaunch: BabelDOCRuntimeLaunch? {
        Self.compatibleManagedRuntimeLaunch(for: runtimeSnapshot)
    }

    func estimatedReclaimableBytes() async -> Int64? {
        guard let runtimeManager else { return nil }
        return await runtimeManager.reclaimableBytes()
    }

    func prepareAtLaunch() {
        guard !launchPreparationCompleted,
            launchPreparationTask == nil
        else { return }
        let preparationID = UUID()
        launchPreparationID = preparationID
        launchPreparationTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await service.cleanupPersistedService()
            } catch {
                guard launchPreparationID == preparationID else { return }
                launchPreparationError = error
                launchPreparationCompleted = true
                launchPreparationTask = nil
                launchPreparationID = nil
                dashboardState = .failed(
                    message: error.localizedDescription,
                    installedVersion: runtimeSnapshot?.currentVersion,
                    canRollback: false
                )
                return
            }
            await Task.detached(priority: .utility) {
                BabelDOCServiceSession.cleanupStaleWorkingDirectories()
            }.value

            guard let runtimeManager else {
                guard launchPreparationID == preparationID else { return }
                launchPreparationCompleted = true
                launchPreparationTask = nil
                launchPreparationID = nil
                refreshDashboard()
                return
            }
            let snapshot = await runtimeManager.snapshot()
            guard launchPreparationID == preparationID else { return }
            runtimeSnapshot = snapshot
            launchPreparationCompleted = true
            launchPreparationTask = nil
            launchPreparationID = nil
            refreshDashboard()
            startBackgroundUpdateCheckIfNeeded()
        }
    }

    func prepareModule() async throws -> PreparedRuntime {
        if let modulePreparationTask {
            return try await modulePreparationTask.value
        }

        let pendingActionTask = actionTask
        let pendingCloseTask = moduleCloseTask
        let pendingCloseID = moduleCloseID
        let task = Task<PreparedRuntime, Error> { [weak self] in
            guard let self else {
                throw CancellationError()
            }
            await pendingActionTask?.value
            try Task.checkCancellation()
            try await waitForModuleClose(pendingCloseTask, id: pendingCloseID)
            return try await installUpdateAndStart()
        }
        let preparationID = UUID()
        modulePreparationTask = task
        modulePreparationID = preparationID
        do {
            let prepared = try await task.value
            if modulePreparationID == preparationID {
                modulePreparationTask = nil
                modulePreparationID = nil
            }
            return prepared
        } catch is CancellationError {
            if modulePreparationID == preparationID {
                modulePreparationTask = nil
                modulePreparationID = nil
            }
            throw CancellationError()
        } catch {
            if modulePreparationID == preparationID {
                modulePreparationTask = nil
                modulePreparationID = nil
            }
            recordFailure(error)
            throw error
        }
    }

    func closeModule() {
        let preparationTask = takeAndCancelModulePreparation()
        activeDocumentName = nil
        let previousCloseTask = moduleCloseTask
        let pendingAction = actionTask
        let closeID = UUID()
        let closeTask = Task { [service] in
            await previousCloseTask?.value
            await pendingAction?.value
            _ = try? await preparationTask?.value
            _ = await service.stop()
        }
        moduleCloseID = closeID
        moduleCloseTask = closeTask
    }

    func closeModuleAndWait() async {
        let preparationTask = takeAndCancelModulePreparation()
        activeDocumentName = nil
        let previousCloseTask = moduleCloseTask
        let pendingAction = actionTask
        let closeID = UUID()
        let closeTask = Task { [service] in
            await previousCloseTask?.value
            await pendingAction?.value
            _ = try? await preparationTask?.value
            _ = await service.stop()
        }
        moduleCloseID = closeID
        moduleCloseTask = closeTask
        await closeTask.value
        if moduleCloseID == closeID {
            moduleCloseTask = nil
            moduleCloseID = nil
        }
    }

    func cancelModulePreparationAndWait() async {
        let preparationTask = takeAndCancelModulePreparation()
        _ = try? await preparationTask?.value
    }

    func shutdown() async {
        prepareAtLaunch()
        let mandatoryLaunchPreparation = launchPreparationTask
        await mandatoryLaunchPreparation?.value
        await cancelBackgroundUpdateCheck()
        let pendingAction = actionTask
        pendingAction?.cancel()
        actionTask = nil
        actionID = nil
        await pendingAction?.value
        await closeModuleAndWait()
    }

    func translationDidStart(fileName: String) {
        activeDocumentName = fileName
        refreshDashboard()
    }

    func translationDidFinish(fileName: String) {
        if activeDocumentName == fileName {
            activeDocumentName = nil
        }
        refreshDashboard()
    }

    func perform(_ action: PDFRuntimeDashboardAction) {
        if action == .cancel {
            Task { [service] in
                try? await service.cancelCurrent()
            }
            return
        }

        let previousAction = actionTask
        previousAction?.cancel()
        let preparationTask = takeAndCancelModulePreparation()
        if action == .retry, launchPreparationError != nil {
            resetLaunchPreparation()
        }
        let pendingCloseTask = moduleCloseTask
        let pendingCloseID = moduleCloseID
        let runtimeVersionBeforeAction = runtimeSnapshot?.currentVersion
        let operationID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await previousAction?.value
            do {
                _ = try? await preparationTask?.value
                try Task.checkCancellation()
                try await waitForLaunchPreparation()
                try await waitForModuleClose(pendingCloseTask, id: pendingCloseID)
                if action != .start, action != .retry {
                    await cancelBackgroundUpdateCheck()
                }
                switch action {
                case .install:
                    _ = try await installUpdateAndStart(forceUpdateCheck: true)
                case .start, .retry:
                    _ = try await installUpdateAndStart()
                case .update:
                    _ = try await updateAndRestart()
                case .reconnect:
                    _ = try await reconnect()
                case .rollback:
                    _ = try await rollbackAndRestart()
                case .uninstall:
                    try await uninstallAndStop()
                case .cancel:
                    break
                }
            } catch is CancellationError {
                // A superseding action or shutdown owns the next state transition.
            } catch {
                recordFailure(
                    error,
                    canRollback: canOfferRollback(
                        after: action,
                        error: error,
                        versionBeforeAction: runtimeVersionBeforeAction
                    )
                )
            }
            if actionID == operationID {
                actionTask = nil
                actionID = nil
            }
        }
        actionID = operationID
        actionTask = task
    }

    private func startObserving() {
        if let runtimeManager {
            runtimeObservationTask = Task { [weak self, runtimeManager] in
                for await snapshot in await runtimeManager.snapshots() {
                    guard let self, !Task.isCancelled else { return }
                    runtimeSnapshot = snapshot
                    refreshDashboard()
                }
            }
        }
        serviceObservationTask = Task { [weak self, service] in
            for await snapshot in await service.stateChanges() {
                guard let self, !Task.isCancelled else { return }
                serviceSnapshot = snapshot
                refreshDashboard()
            }
        }
    }

    private func installUpdateAndStart(
        forceUpdateCheck: Bool = false
    ) async throws -> PreparedRuntime {
        try await waitForLaunchPreparation()
        try Task.checkCancellation()
        guard let runtimeManager else {
            throw ControllerError.runtimeManagerUnavailable
        }

        var changedManagedVersion = false
        var snapshot = await runtimeManager.snapshot()
        runtimeSnapshot = snapshot

        // A verified local runtime is sufficient to start the resident service.
        // Launch-time update discovery remains advisory and must not put the
        // network on the critical path or replace a runtime already in use.
        if let launch = Self.compatibleManagedRuntimeLaunch(for: snapshot) {
            return try await start(launch)
        }

        if snapshot.currentExecutableURL != nil, !forceUpdateCheck {
            await waitForBackgroundUpdateCheck()
            try Task.checkCancellation()
            snapshot = await runtimeManager.snapshot()
            runtimeSnapshot = snapshot
        }

        if snapshot.currentExecutableURL == nil {
            do {
                snapshot = try await runtimeManager.update()
                try Task.checkCancellation()
                changedManagedVersion = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                runtimeSnapshot = await runtimeManager.snapshot()
                throw error
            }
        } else if forceUpdateCheck {
            do {
                snapshot = try await runtimeManager.checkForUpdates()
                try Task.checkCancellation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                snapshot = await runtimeManager.snapshot()
                runtimeSnapshot = snapshot
                throw error
            }
        }

        if Self.managedRuntimePreparation(for: snapshot) == .installAvailableUpdate {
            try await stopServiceForRuntimeReplacement()
            try Task.checkCancellation()
            do {
                snapshot = try await runtimeManager.installAvailableUpdate()
                try Task.checkCancellation()
                changedManagedVersion = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                runtimeSnapshot = await runtimeManager.snapshot()
                throw error
            }
        }
        if case .updateRequired = Self.managedRuntimePreparation(for: snapshot) {
            runtimeSnapshot = snapshot
            throw Self.runtimeUpdateRequiredError(for: snapshot)
        }
        runtimeSnapshot = snapshot

        guard let launch = currentRuntimeLaunch else {
            throw Self.runtimeUpdateRequiredError(for: runtimeSnapshot)
        }
        do {
            return try await start(launch)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logNonfatalUpdateFailure(error)
            guard changedManagedVersion,
                (await runtimeManager.snapshot()).previousVersion != nil
            else {
                throw error
            }
            try await stopServiceForRuntimeReplacement()
            try Task.checkCancellation()
            runtimeSnapshot = try await runtimeManager.rollback()
            try Task.checkCancellation()
            if case .updateRequired = Self.managedRuntimePreparation(for: runtimeSnapshot) {
                throw Self.runtimeUpdateRequiredError(for: runtimeSnapshot)
            }
            guard let rollbackLaunch = currentRuntimeLaunch else {
                throw Self.runtimeUpdateRequiredError(for: runtimeSnapshot)
            }
            return try await start(rollbackLaunch)
        }
    }

    private func updateAndRestart() async throws -> PreparedRuntime {
        guard let runtimeManager else {
            throw ControllerError.runtimeManagerUnavailable
        }
        let versionBeforeUpdate = (await runtimeManager.snapshot()).currentVersion
        try Task.checkCancellation()
        var changedManagedVersion = false
        try await stopServiceForRuntimeReplacement()
        try Task.checkCancellation()
        do {
            let checkedSnapshot = await runtimeManager.snapshot()
            if checkedSnapshot.updateAvailable {
                runtimeSnapshot = try await runtimeManager.installAvailableUpdate()
            } else {
                runtimeSnapshot = try await runtimeManager.update()
            }
            try Task.checkCancellation()
            changedManagedVersion =
                runtimeSnapshot?.currentVersion != versionBeforeUpdate
            if case .updateRequired = Self.managedRuntimePreparation(for: runtimeSnapshot) {
                throw Self.runtimeUpdateRequiredError(for: runtimeSnapshot)
            }
            guard let launch = currentRuntimeLaunch else {
                throw Self.runtimeUpdateRequiredError(for: runtimeSnapshot)
            }
            return try await start(launch)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logNonfatalUpdateFailure(error)
            let snapshot = await runtimeManager.snapshot()
            if changedManagedVersion, snapshot.previousVersion != nil {
                try await stopServiceForRuntimeReplacement()
                runtimeSnapshot = try await runtimeManager.rollback()
                try Task.checkCancellation()
            } else {
                runtimeSnapshot = snapshot
                logNonfatalUpdateFailure(error)
            }
            if case .updateRequired = Self.managedRuntimePreparation(for: runtimeSnapshot) {
                throw Self.runtimeUpdateRequiredError(for: runtimeSnapshot)
            }
            guard let launch = currentRuntimeLaunch else {
                throw error
            }
            return try await start(launch)
        }
    }

    private func rollbackAndRestart() async throws -> PreparedRuntime {
        guard let runtimeManager else {
            throw ControllerError.runtimeManagerUnavailable
        }
        try await stopServiceForRuntimeReplacement()
        try Task.checkCancellation()
        runtimeSnapshot = try await runtimeManager.rollback()
        try Task.checkCancellation()
        guard let launch = currentRuntimeLaunch else {
            throw Self.runtimeUpdateRequiredError(for: runtimeSnapshot)
        }
        return try await start(launch)
    }

    private func uninstallAndStop() async throws {
        guard let runtimeManager else {
            throw ControllerError.runtimeManagerUnavailable
        }
        try await stopServiceForRuntimeReplacement()
        try Task.checkCancellation()
        runtimeSnapshot = try await runtimeManager.uninstall()
        resetLaunchPreparation()
        refreshDashboard()
    }

    private func reconnect() async throws -> PreparedRuntime {
        guard let launch = currentRuntimeLaunch else {
            throw Self.runtimeUpdateRequiredError(for: runtimeSnapshot)
        }
        let baseURL = try await service.reconnect(runtime: launch, force: true)
        let cacheURL = await service.layoutCacheDirectoryURL
        return PreparedRuntime(
            launch: launch,
            layoutServiceBaseURL: baseURL,
            layoutCacheDirectoryURL: cacheURL
        )
    }

    private func stopServiceForRuntimeReplacement() async throws {
        guard await service.stop() else {
            throw BabelDOCServiceError.terminationFailed(
                "BabelDOC 子进程仍在运行，已中止运行时切换。"
            )
        }
    }

    private func waitForLaunchPreparation() async throws {
        if !launchPreparationCompleted {
            prepareAtLaunch()
            await launchPreparationTask?.value
        }
        if let launchPreparationError {
            throw launchPreparationError
        }
    }

    private func resetLaunchPreparation() {
        guard launchPreparationTask == nil else { return }
        launchPreparationID = nil
        launchPreparationCompleted = false
        launchPreparationError = nil
    }

    private func startBackgroundUpdateCheckIfNeeded() {
        guard backgroundUpdateTask == nil,
            runtimeSnapshot?.currentExecutableURL != nil,
            let runtimeManager
        else { return }
        let updateID = UUID()
        backgroundUpdateID = updateID
        backgroundUpdateTask = Task { [weak self, runtimeManager] in
            let checkedSnapshot: BabelDOCRuntimeSnapshot
            do {
                checkedSnapshot = try await runtimeManager.checkForUpdates()
            } catch is CancellationError {
                return
            } catch {
                checkedSnapshot = await runtimeManager.snapshot()
            }
            guard let self,
                !Task.isCancelled,
                backgroundUpdateID == updateID
            else { return }
            runtimeSnapshot = checkedSnapshot
            backgroundUpdateTask = nil
            backgroundUpdateID = nil
            refreshDashboard()
        }
    }

    private func cancelBackgroundUpdateCheck() async {
        let task = backgroundUpdateTask
        task?.cancel()
        await task?.value
        backgroundUpdateTask = nil
        backgroundUpdateID = nil
    }

    private func waitForBackgroundUpdateCheck() async {
        let task = backgroundUpdateTask
        await task?.value
    }

    private func takeAndCancelModulePreparation() -> Task<PreparedRuntime, Error>? {
        let task = modulePreparationTask
        task?.cancel()
        modulePreparationTask = nil
        modulePreparationID = nil
        return task
    }

    func waitForModuleClose(
        _ closeTask: Task<Void, Never>?,
        id closeID: UUID?
    ) async throws {
        await closeTask?.value
        try Task.checkCancellation()
        if moduleCloseID == closeID {
            moduleCloseTask = nil
            moduleCloseID = nil
        }
    }

    private func logNonfatalUpdateFailure(_ error: Error) {
        GlossRuntimeLog.shared.write(
            "pdf-runtime",
            "runtime_update_or_start_failed error=\(error.localizedDescription)"
        )
    }

    private func start(_ launch: BabelDOCRuntimeLaunch) async throws -> PreparedRuntime {
        guard launch == Self.compatibleManagedRuntimeLaunch(for: runtimeSnapshot) else {
            throw Self.runtimeUpdateRequiredError(for: runtimeSnapshot)
        }
        let baseURL = try await service.start(runtime: launch)
        let cacheURL = await service.layoutCacheDirectoryURL
        return PreparedRuntime(
            launch: launch,
            layoutServiceBaseURL: baseURL,
            layoutCacheDirectoryURL: cacheURL
        )
    }

    private func recordFailure(
        _ error: Error,
        canRollback: Bool = false
    ) {
        let installedVersion = runtimeSnapshot?.currentVersion
        dashboardState = .failed(
            message: error.localizedDescription,
            installedVersion: installedVersion,
            canRollback: canRollback
        )
    }

    private func canOfferRollback(
        after action: PDFRuntimeDashboardAction,
        error: Error,
        versionBeforeAction: String?
    ) -> Bool {
        guard action == .install || action == .update,
            let versionBeforeAction,
            runtimeSnapshot?.currentVersion != versionBeforeAction,
            runtimeSnapshot?.previousVersion == versionBeforeAction
        else { return false }
        if let serviceError = error as? BabelDOCServiceError,
            case .terminationFailed = serviceError
        {
            return false
        }
        return true
    }

    private func refreshDashboard() {
        dashboardState = Self.dashboardState(
            runtime: runtimeSnapshot,
            service: serviceSnapshot,
            activeDocumentName: activeDocumentName
        )
    }

    nonisolated static func dashboardState(
        runtime: BabelDOCRuntimeSnapshot?,
        service: BabelDOCExecutorServiceSnapshot,
        activeDocumentName: String?,
        fallbackRuntimeAvailable: Bool = false
    ) -> PDFRuntimeDashboardState {
        if service.lifecycleState != .ready, let runtime {
            switch runtime.operation {
            case .checking:
                return .checking
            case .downloading, .verifying, .extracting, .installing, .rollingBack:
                return .installing(
                    version: runtime.availableVersion ?? runtime.currentVersion,
                    progress: nil
                )
            case .removing:
                return .uninstalling
            case .failed where runtime.currentVersion == nil:
                return .failed(
                    message: runtime.lastError ?? "BabelDOC 运行时操作失败。",
                    installedVersion: nil,
                    canRollback: runtime.previousVersion != nil
                )
            case .idle, .ready, .failed:
                break
            }
        }

        let installedVersion = runtime?.currentVersion ?? service.runtimeVersion
        let canRollback = runtime?.previousVersion != nil
        switch service.lifecycleState {
        case .starting:
            return .starting(version: installedVersion ?? "未知版本")
        case .reconnecting:
            return .reconnecting(previousProcessIdentifier: service.processIdentifier)
        case .failed:
            return .failed(
                message: service.lastError ?? runtime?.lastError ?? "PDF 服务启动失败。",
                installedVersion: installedVersion,
                canRollback: false
            )
        case .ready:
            guard let endpoint = service.endpoint,
                let processIdentifier = service.processIdentifier
            else {
                return .failed(
                    message: "PDF 服务缺少连接身份。",
                    installedVersion: installedVersion,
                    canRollback: false
                )
            }
            let info = PDFRuntimeReadyInfo(
                endpoint: endpoint.absoluteString,
                processIdentifier: processIdentifier,
                version: service.runtimeVersion ?? installedVersion ?? "未知版本",
                executablePath: runtime?.currentExecutableURL?.path
            )
            let activeStatus = service.activeStatus?.lowercased()
            let isActive =
                service.activeTaskID != nil
                && activeStatus != "succeeded"
                && activeStatus != "failed"
                && activeStatus != "cancelled"
            if isActive {
                return .translating(
                    info,
                    fileName: activeDocumentName ?? service.activeTaskID ?? "PDF",
                    progress: service.activeProgress.map {
                        Int(max(0, min(100, $0)).rounded())
                    }
                )
            }
            if let availableVersion = runtime?.availableVersion,
                runtime?.updateAvailable == true
            {
                return .updateAvailable(info, availableVersion: availableVersion)
            }
            return .ready(info)
        case .stopping:
            return .stopping(previousProcessIdentifier: service.processIdentifier)
        case .stopped:
            if installedVersion == nil,
                !fallbackRuntimeAvailable
            {
                return .notInstalled
            }
            return .stopped(
                installedVersion: installedVersion,
                canRollback: canRollback
            )
        }
    }

    private nonisolated static func managedLaunch(
        executable: URL,
        version: String?
    ) -> BabelDOCRuntimeLaunch {
        BabelDOCRuntimeLaunch(
            executable: executable.path,
            source: version.map { "Gloss runtime \($0)" } ?? "Gloss runtime",
            executorExecutable: executable.path
        )
    }

    nonisolated static func compatibleManagedRuntimeLaunch(
        for snapshot: BabelDOCRuntimeSnapshot?
    ) -> BabelDOCRuntimeLaunch? {
        guard let snapshot,
            let executable = snapshot.currentExecutableURL,
            isCompatibleManagedRuntimeVersion(snapshot.currentVersion)
        else {
            return nil
        }
        return managedLaunch(
            executable: executable,
            version: snapshot.currentVersion
        )
    }

    nonisolated static func managedRuntimePreparation(
        for snapshot: BabelDOCRuntimeSnapshot?
    ) -> ManagedRuntimePreparation {
        switch BabelDOCRuntimeCompatibility.preparation(
            for: snapshot
        ) {
        case .install:
            return .install
        case .installAvailableUpdate:
            return .installAvailableUpdate
        case .useCurrent:
            return .startCurrent
        case .updateRequired(let currentVersion):
            return .updateRequired(
                currentVersion: currentVersion == "unknown"
                    ? "未知版本"
                    : currentVersion
            )
        }
    }

    nonisolated static func isCompatibleManagedRuntimeVersion(
        _ version: String?
    ) -> Bool {
        BabelDOCRuntimeCompatibility.isCompatible(version)
    }

    private nonisolated static func runtimeUpdateRequiredError(
        for snapshot: BabelDOCRuntimeSnapshot?
    ) -> ControllerError {
        ControllerError.runtimeUpdateRequired(
            current: snapshot?.currentVersion ?? "未知版本",
            minimum: minimumCompatibleManagedRuntimeVersion
        )
    }
}
