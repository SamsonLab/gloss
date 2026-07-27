import Darwin
import Foundation
import GlossCore

enum PDFScenarioCommand {
    private struct Output: Codable {
        let input: String
        let outputs: [String]
    }

    static func run(_ options: GlossCLIPDFOptions) async throws -> String {
        let inputs = try options.inputPaths.map(resolvePDF)
        let outputDirectory = URL(
            fileURLWithPath: options.outputDirectoryPath,
            isDirectory: true
        ).standardizedFileURL
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        guard
            let targetLanguageCode =
                TranslationLanguages.babelDOCCode(
                    forTargetName: options.targetLanguage
                )
        else {
            throw GlossCLIUsageError(
                "BabelDOC 暂不支持目标语言：\(options.targetLanguage)"
            )
        }

        guard let glossVersion = GlossProductVersionResolver.resolve() else {
            throw GlossCLIUsageError(
                "无法确定 Gloss 版本，不能安全验证 BabelDOC runtime manifest。"
            )
        }
        let runtimeManager = try BabelDOCRuntimeManager(
            currentGlossVersion: glossVersion
        )
        let runtimeSnapshot = try await managedRuntime(
            from: runtimeManager
        )
        guard let executableURL = runtimeSnapshot.currentExecutableURL,
            BabelDOCRuntimeCompatibility.isCompatible(
                runtimeSnapshot.currentVersion
            )
        else {
            throw GlossCLIUsageError(
                "BabelDOC runtime 需要 \(BabelDOCRuntimeCompatibility.minimumManagedVersion) 或更高版本。"
            )
        }
        let runtime = BabelDOCRuntimeLaunch(
            executable: executableURL.path,
            source: runtimeSnapshot.currentVersion.map {
                "Gloss runtime \($0)"
            } ?? "Gloss runtime",
            executorExecutable: executableURL.path
        )

        let privateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Gloss-CLI-PDF-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: privateRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let stateDirectory = privateRoot.appendingPathComponent(
            "service-state",
            isDirectory: true
        )
        let service = BabelDOCServiceSession(
            persistedStateDirectoryURL: stateDirectory
        )
        let provider = ProviderHandle(
            provider: options.provider,
            model: options.model,
            reasoningEffort: options.reasoningEffort
        )
        let token = UUID().uuidString + UUID().uuidString
        let port = try availableLoopbackPort()
        let bridge = LoopbackServer(
            broker: TranslationBroker(backend: provider.backend),
            token: token,
            version: glossVersion,
            port: port,
            providerStatus: { provider.status }
        )

        do {
            try bridge.start()
            let bridgeBaseURL = URL(
                string: "http://127.0.0.1:\(port)"
            )!
            try await waitForBridge(
                bridgeBaseURL,
                token: token
            )
            StandardError.write(
                "pdf: 正在启动独立 BabelDOC 服务…\n"
            )
            let layoutServiceBaseURL = try await service.start(
                runtime: runtime
            )
            let layoutCacheDirectoryURL =
                await service.layoutCacheDirectoryURL
            let engine = BabelDOCExternalEngine(
                executorManager: service
            )
            var records: [Output] = []

            for (index, input) in inputs.enumerated() {
                try Task.checkCancellation()
                let jobDirectory = privateRoot.appendingPathComponent(
                    "job-\(index + 1)",
                    isDirectory: true
                )
                StandardError.write(
                    "pdf: [\(index + 1)/\(inputs.count)] \(input.lastPathComponent)\n"
                )
                let result = try await engine.translate(
                    BabelDOCTranslationRequest(
                        inputURL: input,
                        outputDirectory: jobDirectory,
                        sourceLanguageCode: options.sourceLanguageCode,
                        targetLanguageCode: targetLanguageCode,
                        bridgeBaseURL: bridgeBaseURL.appendingPathComponent(
                            "v1"
                        ),
                        bridgeToken: token,
                        outputMode: options.outputMode,
                        layoutServiceBaseURL: layoutServiceBaseURL,
                        layoutCacheDirectoryURL:
                            layoutCacheDirectoryURL
                    ),
                    runtime: runtime,
                    onProgress: { progress in
                        StandardError.write(
                            progressLine(
                                progress,
                                item: index + 1,
                                count: inputs.count
                            )
                        )
                    }
                )
                let generated: URL? =
                    switch options.outputMode {
                    case .monolingual:
                        result.monolingualPDF
                    case .bilingual:
                        result.bilingualPDF
                    }
                guard let generated else {
                    throw BabelDOCExternalEngineError.outputMissing
                }
                let destination = availableDestination(
                    for: input,
                    mode: options.outputMode,
                    in: outputDirectory
                )
                try FileManager.default.copyItem(
                    at: generated,
                    to: destination
                )
                records.append(
                    Output(
                        input: input.path,
                        outputs: [destination.path]
                    )
                )
            }

            bridge.stop()
            _ = await service.stop()
            await provider.stop()
            try? FileManager.default.removeItem(at: privateRoot)
            return try JSONOutput.encode(records)
        } catch {
            bridge.stop()
            _ = await service.stop()
            await provider.stop()
            try? FileManager.default.removeItem(at: privateRoot)
            throw error
        }
    }

    private static func managedRuntime(
        from manager: BabelDOCRuntimeManager
    ) async throws -> BabelDOCRuntimeSnapshot {
        let snapshot = await manager.snapshot()
        if snapshot.currentExecutableURL != nil,
            BabelDOCRuntimeCompatibility.isCompatible(
                snapshot.currentVersion
            )
        {
            return snapshot
        }

        let progress: BabelDOCRuntimeManager.ProgressHandler = {
            update in
            let version = update.version.map { " \($0)" } ?? ""
            StandardError.write(
                "runtime: \(update.operation.rawValue)\(version)\n"
            )
        }
        if snapshot.currentExecutableURL == nil {
            return try await manager.update(progress: progress)
        }

        let checked = try await manager.checkForUpdates(
            progress: progress
        )
        guard checked.updateAvailable,
            BabelDOCRuntimeCompatibility.isCompatible(
                checked.availableVersion
            )
        else {
            throw GlossCLIUsageError(
                "已安装 BabelDOC runtime \(snapshot.currentVersion ?? "unknown") 不兼容，且没有可用的兼容更新。"
            )
        }
        return try await manager.installAvailableUpdate(
            progress: progress
        )
    }

    private static func resolvePDF(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey]
        )
        guard values?.isRegularFile == true,
            url.pathExtension.lowercased() == "pdf"
        else {
            throw GlossCLIUsageError(
                "不是可读取的 PDF 文件：\(path)"
            )
        }
        return url
    }

    private static func availableDestination(
        for input: URL,
        mode: BabelDOCOutputMode,
        in outputDirectory: URL
    ) -> URL {
        let stem = input.deletingPathExtension().lastPathComponent
        let suffix =
            mode == .monolingual ? "gloss-mono" : "gloss-dual"
        var candidate = outputDirectory.appendingPathComponent(
            "\(stem)-\(suffix).pdf"
        )
        var copy = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = outputDirectory.appendingPathComponent(
                "\(stem)-\(suffix)-\(copy).pdf"
            )
            copy += 1
        }
        return candidate
    }

    private static func progressLine(
        _ progress: BabelDOCProgressUpdate,
        item: Int,
        count: Int
    ) -> String {
        let percent = Int(progress.overallProgress.rounded())
        let stage = progress.stageName.map { " \($0)" } ?? ""
        return
            "pdf: [\(item)/\(count)] \(progress.phase.rawValue) \(percent)%\(stage)\n"
    }

    private static func availableLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw GlossCLIUsageError("无法创建 CLI 翻译桥接端口。")
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else {
            throw GlossCLIUsageError("无法绑定 CLI 翻译桥接端口。")
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let readResult = withUnsafeMutablePointer(
            to: &boundAddress
        ) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard readResult == 0 else {
            throw GlossCLIUsageError("无法读取 CLI 翻译桥接端口。")
        }
        return UInt16(bigEndian: boundAddress.sin_port)
    }

    private static func waitForBridge(
        _ baseURL: URL,
        token: String
    ) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.5
        configuration.timeoutIntervalForResource = 0.5
        let session = URLSession(configuration: configuration)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            try Task.checkCancellation()
            var request = URLRequest(
                url: baseURL.appendingPathComponent("health")
            )
            request.setValue(token, forHTTPHeaderField: "X-Gloss-Token")
            if let (_, response) = try? await session.data(for: request),
                (response as? HTTPURLResponse)?.statusCode == 200
            {
                return
            }
            try await Task.sleep(for: .milliseconds(80))
        }
        throw GlossCLIUsageError(
            "CLI 翻译桥接服务启动超时。"
        )
    }
}
