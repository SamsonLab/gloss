import AppKit
import GlossCore
import PDFKit
import UniformTypeIdentifiers

private enum PDFTranslationWindowError: LocalizedError {
    case cannotOpen
    case locked
    case emptyDocument
    case cannotCopyOutput

    var errorDescription: String? {
        switch self {
        case .cannotOpen:
            "无法打开这个 PDF。"
        case .locked:
            "这个 PDF 受密码保护，Gloss 暂时无法翻译。"
        case .emptyDocument:
            "这个 PDF 没有可读取的页面。"
        case .cannotCopyOutput:
            "无法保存 BabelDOC 译文 PDF。"
        }
    }
}

@MainActor
final class PDFTranslationWindowController: NSObject, NSWindowDelegate {
    private let targetLanguage: () -> String
    private let bridgeToken: () -> String?
    private let translationDispatchState: TranslationDispatchState
    private let babelDOCExternalEngine = BabelDOCExternalEngine()

    private let window: NSWindow
    private let pdfView = PDFView()
    private let fileLabel = NSTextField(labelWithString: "PDF 翻译")
    private let statusLabel = NSTextField(labelWithString: "选择一个 PDF 开始")
    private let timingLabel = NSTextField(labelWithString: "")
    private let pageLabel = NSTextField(labelWithString: "—")
    private let progressIndicator = NSProgressIndicator()
    private let outputModeControl = NSSegmentedControl(
        labels: ["Mono 单语", "Dual 双语"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)
    private let translateButton = NSButton(
        title: "BabelDOC 翻译并保存…",
        target: nil,
        action: nil
    )

    private var documentURL: URL?
    private var layoutTranslationTask: Task<Void, Never>?
    private var progressRefreshTask: Task<Void, Never>?
    private var layoutTranslationID: UUID?
    private var translationStartedAt: Date?
    private var latestProgress: BabelDOCProgressUpdate?
    private var latestPerformance =
        TranslationDispatchState.DocumentPerformanceSnapshot()

    init(
        targetLanguage: @escaping () -> String,
        bridgeToken: @escaping () -> String?,
        translationDispatchState: TranslationDispatchState
    ) {
        self.targetLanguage = targetLanguage
        self.bridgeToken = bridgeToken
        self.translationDispatchState = translationDispatchState
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        super.init()
        configureWindow()
    }

    func open(_ url: URL, pageIndex requestedPageIndex: Int = 0) throws {
        guard let document = PDFDocument(url: url) else {
            throw PDFTranslationWindowError.cannotOpen
        }
        guard !document.isLocked else {
            throw PDFTranslationWindowError.locked
        }
        guard document.pageCount > 0 else {
            throw PDFTranslationWindowError.emptyDocument
        }

        stop()
        documentURL = url
        pdfView.document = document
        let pageIndex = min(max(0, requestedPageIndex), document.pageCount - 1)
        if let requestedPage = document.page(at: pageIndex) {
            pdfView.go(to: requestedPage)
        }
        fileLabel.stringValue = url.lastPathComponent
        window.title = "\(url.lastPathComponent) — Gloss BabelDOC"
        updatePageLabel()
        statusLabel.stringValue =
            "选择 Mono 或 Dual；Gloss 将通过当前 provider 翻译完整文档"
        timingLabel.stringValue = ""
        updateTranslateButton()

        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func translationConfigurationDidChange() {
        guard documentURL != nil else { return }
        statusLabel.stringValue = "翻译 provider 已更新"
        updateTranslateButton()
    }

    func stop() {
        layoutTranslationID = nil
        layoutTranslationTask?.cancel()
        layoutTranslationTask = nil
        progressRefreshTask?.cancel()
        progressRefreshTask = nil
        finishRunning()
    }

    func windowWillClose(_ notification: Notification) {
        stop()
    }

    private var outputMode: BabelDOCOutputMode {
        outputModeControl.selectedSegment == 1 ? .bilingual : .monolingual
    }

    private func configureWindow() {
        window.title = "PDF 翻译 — Gloss BabelDOC"
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = NSView()
        window.contentView = content

        let header = NSVisualEffectView()
        header.material = .headerView
        header.blendingMode = .withinWindow
        header.state = .active
        header.translatesAutoresizingMaskIntoConstraints = false

        fileLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        timingLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timingLabel.textColor = .tertiaryLabelColor
        timingLabel.lineBreakMode = .byTruncatingTail
        timingLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        let titleStack = NSStackView(views: [fileLabel, statusLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2

        pageLabel.font = .monospacedDigitSystemFont(
            ofSize: 12,
            weight: .medium
        )
        pageLabel.textColor = .secondaryLabelColor

        progressIndicator.style = .bar
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.isHidden = true

        outputModeControl.selectedSegment = 0
        outputModeControl.setToolTip(
            "只生成中文单语 PDF，速度更快",
            forSegment: 0
        )
        outputModeControl.setToolTip(
            "只生成原文与译文对照 PDF",
            forSegment: 1
        )

        stopButton.target = self
        stopButton.action = #selector(stopTranslation)
        stopButton.bezelStyle = .rounded
        stopButton.isEnabled = false

        translateButton.target = self
        translateButton.action = #selector(exportWithBabelDOC)
        translateButton.bezelStyle = .rounded
        updateTranslateButton()

        let headerStack = NSStackView(views: [
            titleStack,
            NSView(),
            pageLabel,
            progressIndicator,
            outputModeControl,
            stopButton,
            translateButton,
        ])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 10
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerStack)
        timingLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(timingLabel)

        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .windowBackgroundColor

        content.addSubview(header)
        content.addSubview(pdfView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 86),

            headerStack.leadingAnchor.constraint(
                equalTo: header.leadingAnchor,
                constant: 18
            ),
            headerStack.trailingAnchor.constraint(
                equalTo: header.trailingAnchor,
                constant: -18
            ),
            headerStack.topAnchor.constraint(equalTo: header.topAnchor, constant: 10),
            progressIndicator.widthAnchor.constraint(equalToConstant: 112),

            timingLabel.leadingAnchor.constraint(
                equalTo: header.leadingAnchor,
                constant: 18
            ),
            timingLabel.trailingAnchor.constraint(
                equalTo: header.trailingAnchor,
                constant: -18
            ),
            timingLabel.bottomAnchor.constraint(
                equalTo: header.bottomAnchor,
                constant: -8
            ),

            pdfView.topAnchor.constraint(equalTo: header.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pdfPageChanged),
            name: .PDFViewPageChanged,
            object: pdfView
        )
    }

    @objc private func pdfPageChanged() {
        updatePageLabel()
    }

    private func updatePageLabel() {
        guard let document = pdfView.document,
            let page = pdfView.currentPage
        else {
            pageLabel.stringValue = "—"
            return
        }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }
        pageLabel.stringValue = "第 \(index + 1) / \(document.pageCount) 页"
    }

    @objc private func stopTranslation() {
        layoutTranslationTask?.cancel()
        statusLabel.stringValue = "正在停止 BabelDOC…"
    }

    @objc private func exportWithBabelDOC() {
        guard let runtime = BabelDOCExternalEngine.resolveRuntime() else {
            showBabelDOCInstallationHelp()
            return
        }
        guard let documentURL, let token = bridgeToken() else {
            statusLabel.stringValue = "Gloss 本地翻译桥接尚未就绪"
            return
        }
        guard
            let targetCode = TranslationLanguages.babelDOCCode(
                forTargetName: targetLanguage()
            )
        else {
            statusLabel.stringValue = "BabelDOC 暂不支持当前目标语言"
            return
        }

        let selectedMode = outputMode
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        let suffix =
            selectedMode == .monolingual
            ? "-gloss-mono.pdf"
            : "-gloss-dual.pdf"
        panel.nameFieldStringValue =
            documentURL.deletingPathExtension().lastPathComponent + suffix
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else {
                return
            }
            startBabelDOCTranslation(
                inputURL: documentURL,
                destination: destination,
                runtime: runtime,
                bridgeToken: token,
                targetLanguageCode: targetCode,
                outputMode: selectedMode
            )
        }
    }

    private func showBabelDOCInstallationHelp() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "需要安装 BabelDOC"
        alert.informativeText = """
            PDF 翻译仅使用独立安装的 BabelDOC。

            安装命令：
            uv tool install --python 3.12 BabelDOC

            也可以通过 GLOSS_BABELDOC_BIN 指定可执行文件。
            """
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    private func startBabelDOCTranslation(
        inputURL: URL,
        destination: URL,
        runtime: BabelDOCRuntimeLaunch,
        bridgeToken: String,
        targetLanguageCode: String,
        outputMode: BabelDOCOutputMode
    ) {
        stop()
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Gloss-BabelDOC-\(UUID().uuidString)",
                isDirectory: true
            )
        let sampledPageTexts = (0..<min(5, pdfView.document?.pageCount ?? 0))
            .map { pdfView.document?.page(at: $0)?.string }
        let sourceText =
            sampledPageTexts
            .compactMap { $0 }
            .joined(separator: "\n")
        let skipScannedDetection = BabelDOCExternalEngine.hasReliableTextLayer(
            sampledPageTexts
        )
        let detectedSource =
            TranslationLanguages.detectedSourceLanguageCode(in: sourceText)
            ?? "en"
        let sourceLanguageCode = babelDOCSourceCode(detectedSource)

        translateButton.isEnabled = false
        outputModeControl.isEnabled = false
        stopButton.isEnabled = true
        progressIndicator.isHidden = false
        progressIndicator.isIndeterminate = true
        progressIndicator.doubleValue = 0
        progressIndicator.startAnimation(nil)
        statusLabel.stringValue = "正在启动 BabelDOC 翻译服务…"
        timingLabel.stringValue = "启动 0.0s"
        translationStartedAt = Date()
        latestProgress = nil
        latestPerformance = .init()

        let taskID = UUID()
        layoutTranslationID = taskID
        startProgressRefresh(for: taskID)
        layoutTranslationTask = Task { [weak self] in
            guard let self else { return }
            await translationDispatchState.beginDocumentPerformanceRun(id: taskID)
            var completedTimings: BabelDOCPhaseTimings?
            defer {
                try? FileManager.default.removeItem(at: outputDirectory)
                if layoutTranslationID == taskID {
                    layoutTranslationID = nil
                    layoutTranslationTask = nil
                    finishRunning()
                }
            }
            do {
                let result = try await babelDOCExternalEngine.translate(
                    BabelDOCTranslationRequest(
                        inputURL: inputURL,
                        outputDirectory: outputDirectory,
                        sourceLanguageCode: sourceLanguageCode,
                        targetLanguageCode: targetLanguageCode,
                        bridgeBaseURL: URL(
                            string: "http://127.0.0.1:8787/v1"
                        )!,
                        bridgeToken: bridgeToken,
                        qps: 8,
                        maximumPagesPerPart: Self.babelDOCMaximumPagesPerPart(),
                        skipScannedDetection: skipScannedDetection,
                        outputMode: outputMode
                    ),
                    runtime: runtime,
                    onProgress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            await self?.showProgress(progress, for: taskID)
                        }
                    }
                )
                completedTimings = result.timings
                await Task.yield()
                try Task.checkCancellation()
                let generated =
                    outputMode == .monolingual
                    ? result.monolingualPDF
                    : result.bilingualPDF
                guard let generated else {
                    throw BabelDOCExternalEngineError.outputMissing
                }
                try copyReplacing(generated, to: destination)
                statusLabel.stringValue =
                    "BabelDOC 译文已保存：\(destination.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch is CancellationError {
                statusLabel.stringValue = "已停止 BabelDOC 翻译"
            } catch {
                statusLabel.stringValue =
                    "BabelDOC 翻译失败：\(error.localizedDescription)"
            }
            let performance =
                await translationDispatchState
                .endDocumentPerformanceRun(id: taskID)
            if let performance, layoutTranslationID == taskID {
                latestPerformance = performance
                updateTimingLabel()
            }
            if let completedTimings, let performance {
                let wallMilliseconds =
                    translationStartedAt.map {
                        Int(Date().timeIntervalSince($0) * 1_000)
                    } ?? 0
                GlossRuntimeLog.shared.write(
                    "pdf",
                    "translation_complete mode=\(outputMode.rawValue) wall_ms=\(wallMilliseconds) launching_ms=\(completedTimings.launchingMilliseconds) parsing_ms=\(completedTimings.parsingMilliseconds) translating_ms=\(completedTimings.translatingMilliseconds) typesetting_ms=\(completedTimings.typesettingMilliseconds) saving_ms=\(completedTimings.savingMilliseconds) model_prepare_ms=\(performance.preparationMilliseconds) model_wait_ms=\(performance.modelWaitMilliseconds) model_output_stream_ms=\(performance.outputStreamMilliseconds) model_turn_ms=\(performance.totalTurnMilliseconds) model_turns=\(performance.completedTurns)"
                )
            }
        }
    }

    private func copyReplacing(_ source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw PDFTranslationWindowError.cannotCopyOutput
        }
    }

    private func babelDOCSourceCode(_ detectedCode: String) -> String {
        let normalized = detectedCode.lowercased()
        if normalized.hasPrefix("zh-hant") {
            return "zh-TW"
        }
        if normalized.hasPrefix("zh") {
            return "zh-CN"
        }
        return normalized.split(separator: "-", maxSplits: 1).first
            .map(String.init)
            ?? "en"
    }

    nonisolated private static func babelDOCMaximumPagesPerPart(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let rawValue = environment["GLOSS_BABELDOC_PAGE_GROUP_SIZE"],
            let value = Int(rawValue),
            (4...200).contains(value)
        else { return 50 }
        return value
    }

    private func startProgressRefresh(for taskID: UUID) {
        progressRefreshTask?.cancel()
        progressRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task<Never, Never>.sleep(nanoseconds: 500_000_000)
                } catch {
                    return
                }
                guard let self, layoutTranslationID == taskID else { return }
                if let performance =
                    await translationDispatchState
                    .documentPerformanceSnapshot(for: taskID)
                {
                    latestPerformance = performance
                }
                updateTimingLabel()
            }
        }
    }

    private func showProgress(
        _ progress: BabelDOCProgressUpdate,
        for taskID: UUID
    ) async {
        guard layoutTranslationID == taskID else { return }
        latestProgress = progress
        if let performance =
            await translationDispatchState
            .documentPerformanceSnapshot(for: taskID)
        {
            latestPerformance = performance
        }

        switch progress.phase {
        case .launching:
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
        default:
            progressIndicator.stopAnimation(nil)
            progressIndicator.isIndeterminate = false
            progressIndicator.doubleValue = max(1, progress.overallProgress)
        }

        let percent = Int(progress.overallProgress.rounded())
        let part: String
        if let partIndex = progress.partIndex,
            let totalParts = progress.totalParts,
            totalParts > 1
        {
            part = " · 第 \(partIndex)/\(totalParts) 组"
        } else {
            part = ""
        }
        switch progress.phase {
        case .launching:
            statusLabel.stringValue = "正在启动 BabelDOC 翻译服务…"
        case .parsing:
            statusLabel.stringValue = "正在解析页面与版面 · \(percent)%\(part)"
        case .translating:
            statusLabel.stringValue = "模型正在翻译 · \(percent)%\(part)"
        case .typesetting:
            statusLabel.stringValue = "正在排版并恢复原始样式 · \(percent)%\(part)"
        case .saving:
            statusLabel.stringValue = "正在生成 PDF · \(percent)%\(part)"
        case .finalizing:
            statusLabel.stringValue = "正在整理输出文件 · \(percent)%"
        case .completed:
            statusLabel.stringValue = "BabelDOC 处理完成，正在保存…"
        }
        updateTimingLabel()
    }

    private func updateTimingLabel() {
        let timings = latestProgress?.timings ?? BabelDOCPhaseTimings()
        var launching = timings.launchingMilliseconds
        if latestProgress == nil || latestProgress?.phase == .launching,
            let translationStartedAt
        {
            launching = max(
                launching,
                Int(Date().timeIntervalSince(translationStartedAt) * 1_000)
            )
        }
        var components = ["启动 \(formattedDuration(launching))"]
        if latestProgress?.phase != .launching {
            components.append("解析 \(formattedDuration(timings.parsingMilliseconds))")
            if latestPerformance.completedTurns > 0 {
                components.append(
                    "模型准备累计 \(formattedDuration(latestPerformance.preparationMilliseconds))"
                )
                components.append(
                    "模型等待累计 \(formattedDuration(latestPerformance.modelWaitMilliseconds))"
                )
            } else {
                components.append("模型等待 —")
            }
            components.append(
                "排版 \(formattedDuration(timings.typesettingMilliseconds))"
            )
            components.append("保存 \(formattedDuration(timings.savingMilliseconds))")
            if latestPerformance.completedTurns > 0 {
                components.append("\(latestPerformance.completedTurns) 批")
            }
        }
        timingLabel.stringValue = components.joined(separator: " · ")
    }

    private func formattedDuration(_ milliseconds: Int) -> String {
        String(format: "%.1fs", Double(max(0, milliseconds)) / 1_000)
    }

    private func updateTranslateButton() {
        let runtime = BabelDOCExternalEngine.resolveRuntime()
        translateButton.isEnabled =
            layoutTranslationTask == nil && documentURL != nil
        if let runtime {
            translateButton.title = "BabelDOC 翻译并保存…"
            translateButton.toolTip =
                "使用 \(runtime.source) BabelDOC；一次只生成所选 Mono 或 Dual PDF"
        } else {
            translateButton.title = "安装 BabelDOC…"
            translateButton.toolTip =
                "执行 uv tool install --python 3.12 BabelDOC 后即可使用"
        }
    }

    private func finishRunning() {
        progressRefreshTask?.cancel()
        progressRefreshTask = nil
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        stopButton.isEnabled = false
        outputModeControl.isEnabled = true
        updateTranslateButton()
    }
}
