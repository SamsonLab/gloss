import Foundation
import GlossCore

enum AppUpdateStagingCleaner {
    enum CleanupError: Error, Equatable {
        case invalidDirectory
    }

    static func removeStagedHelpers(
        at stagingRootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let standardizedURL = stagingRootURL.standardizedFileURL
        guard standardizedURL.lastPathComponent == "staging",
            standardizedURL.deletingLastPathComponent().lastPathComponent
                == "AppUpdater"
        else {
            throw CleanupError.invalidDirectory
        }
        guard fileManager.fileExists(atPath: standardizedURL.path) else {
            return
        }
        try fileManager.removeItem(at: standardizedURL)
    }
}

@MainActor
final class AppUpdateController {
    struct Dependencies {
        var check:
            (GlossAppUpdateCheckMode) async throws
                -> GlossAppUpdateCheckResult
        var detectHomebrewInstallation:
            () async throws
                -> GlossHomebrewInstallation?
        var launchHomebrewUpdate:
            (
                GlossHomebrewInstallation,
                GlossAppUpdateAvailability
            ) async throws -> Void
        var openReleasePage: (URL) -> Bool
        var isBusinessTaskActive: () async -> Bool
        var requestApplicationTermination: () -> Void
        var operatingSystemVersion: () -> OperatingSystemVersion
    }

    private(set) var state: AppUpdateDashboardState {
        didSet {
            onStateChange?(state)
        }
    }

    var onStateChange: ((AppUpdateDashboardState) -> Void)?

    private let currentVersion: String
    private let dependencies: Dependencies
    private var automaticCheckTask: Task<Void, Never>?
    private var operationInProgress = false

    init(
        currentVersion: String,
        dependencies: Dependencies,
        initialState: AppUpdateDashboardState? = nil
    ) {
        self.currentVersion = currentVersion
        self.dependencies = dependencies
        state = initialState ?? .idle(currentVersion: currentVersion)
    }

    func startAutomaticCheck(
        after delay: Duration = .seconds(4)
    ) {
        guard automaticCheckTask == nil else { return }
        automaticCheckTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await check(mode: .automatic)
        }
    }

    func cancel() {
        automaticCheckTask?.cancel()
        automaticCheckTask = nil
    }

    func check(mode: GlossAppUpdateCheckMode) async {
        guard !operationInProgress else { return }
        operationInProgress = true
        let previousState = state
        state = .checking(currentVersion: currentVersion)
        defer { operationInProgress = false }

        do {
            let result = try await dependencies.check(mode)
            switch result {
            case .throttled:
                state =
                    if case .checking = previousState {
                        .idle(currentVersion: currentVersion)
                    } else {
                        previousState
                    }
            case .upToDate(let latestVersion):
                state = .upToDate(
                    currentVersion: currentVersion,
                    latestVersion: latestVersion
                )
            case .updateAvailable(let update):
                guard
                    Self.supports(
                        minimumMacOSVersion: update.minimumMacOSVersion,
                        current: dependencies.operatingSystemVersion()
                    )
                else {
                    state = .unavailable(
                        currentVersion: currentVersion,
                        reason:
                            "Gloss \(update.version) 需要 macOS \(update.minimumMacOSVersion) 或更高版本"
                    )
                    return
                }

                let installation =
                    try await dependencies.detectHomebrewInstallation()
                state = .updateAvailable(
                    update,
                    delivery: installation.map(AppUpdateDelivery.homebrew)
                        ?? .releasePage
                )
            }
        } catch is CancellationError {
            state = previousState
        } catch {
            state = .failed(
                currentVersion: currentVersion,
                message: error.localizedDescription
            )
        }
    }

    func performPrimaryAction() async {
        guard let action = state.action else { return }
        switch action {
        case .check:
            await check(mode: .manual)
        case .openReleasePage:
            guard case .updateAvailable(let update, .releasePage) = state else {
                return
            }
            if !dependencies.openReleasePage(update.releasePageURL) {
                state = .failed(
                    currentVersion: currentVersion,
                    message: "无法打开官方发布页面。"
                )
            }
        case .install:
            await installAvailableUpdate()
        }
    }

    static func supports(
        minimumMacOSVersion: String,
        current: OperatingSystemVersion
    ) -> Bool {
        let parts = minimumMacOSVersion.split(separator: ".")
        guard (2...3).contains(parts.count),
            let major = Int(parts[0]),
            let minor = Int(parts[1])
        else {
            return false
        }
        let patch: Int
        if parts.count == 3 {
            guard let parsedPatch = Int(parts[2]) else { return false }
            patch = parsedPatch
        } else {
            patch = 0
        }
        let required = OperatingSystemVersion(
            majorVersion: major,
            minorVersion: minor,
            patchVersion: patch
        )
        let currentParts = [
            current.majorVersion,
            current.minorVersion,
            current.patchVersion,
        ]
        let requiredParts = [
            required.majorVersion,
            required.minorVersion,
            required.patchVersion,
        ]
        return !currentParts.lexicographicallyPrecedes(requiredParts)
    }

    private func installAvailableUpdate() async {
        guard !operationInProgress else { return }

        let update: GlossAppUpdateAvailability
        let installation: GlossHomebrewInstallation
        switch state {
        case .updateAvailable(let available, .homebrew(let managedInstallation)):
            update = available
            installation = managedInstallation
        case .blockedByBusinessTask(
            let available,
            let managedInstallation
        ):
            update = available
            installation = managedInstallation
        default:
            return
        }

        guard !(await dependencies.isBusinessTaskActive()) else {
            state = .blockedByBusinessTask(
                update,
                installation: installation
            )
            return
        }

        operationInProgress = true
        state = .preparingInstall(version: update.version)
        defer { operationInProgress = false }

        do {
            try await dependencies.launchHomebrewUpdate(
                installation,
                update
            )
            dependencies.requestApplicationTermination()
        } catch {
            state = .failed(
                currentVersion: currentVersion,
                message: error.localizedDescription
            )
        }
    }
}
