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
    private let babelDOCExternalEngine = BabelDOCExternalEngine()

    private let window: NSWindow
    private let pdfView = PDFView()
    private let fileLabel = NSTextField(labelWithString: "PDF 翻译")
    private let statusLabel = NSTextField(labelWithString: "选择一个 PDF 开始")
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
    private var layoutTranslationID: UUID?

    init(
        targetLanguage: @escaping () -> String,
        bridgeToken: @escaping () -> String?
    ) {
        self.targetLanguage = targetLanguage
        self.bridgeToken = bridgeToken
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

        let titleStack = NSStackView(views: [fileLabel, statusLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2

        pageLabel.font = .monospacedDigitSystemFont(
            ofSize: 12,
            weight: .medium
        )
        pageLabel.textColor = .secondaryLabelColor

        progressIndicator.style = .spinning
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
            header.heightAnchor.constraint(equalToConstant: 64),

            headerStack.leadingAnchor.constraint(
                equalTo: header.leadingAnchor,
                constant: 18
            ),
            headerStack.trailingAnchor.constraint(
                equalTo: header.trailingAnchor,
                constant: -18
            ),
            headerStack.centerYAnchor.constraint(
                equalTo: header.centerYAnchor
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
        progressIndicator.startAnimation(nil)
        statusLabel.stringValue =
            outputMode == .monolingual
            ? "BabelDOC 正在生成 Mono 单语 PDF；高速预取、双路模型翻译已启用…"
            : "BabelDOC 正在生成 Dual 双语 PDF；高速预取、双路模型翻译已启用…"

        let taskID = UUID()
        layoutTranslationID = taskID
        layoutTranslationTask = Task { [weak self] in
            guard let self else { return }
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
                        skipScannedDetection: skipScannedDetection,
                        outputMode: outputMode
                    ),
                    runtime: runtime
                ) { [weak self] output in
                    guard
                        let summary = Self.babelDOCProgressSummary(output)
                    else { return }
                    Task { @MainActor [weak self] in
                        self?.statusLabel.stringValue = summary
                    }
                }
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

    nonisolated private static func babelDOCProgressSummary(
        _ output: String
    ) -> String? {
        let cleaned =
            output
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .last(where: { !$0.isEmpty })
        guard let cleaned else { return nil }
        if let percent = cleaned.range(
            of: #"\d{1,3}(?:\.\d+)?%"#,
            options: .regularExpression
        ) {
            return "BabelDOC 翻译 \(cleaned[percent])"
        }
        return nil
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
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        stopButton.isEnabled = false
        outputModeControl.isEnabled = true
        updateTranslateButton()
    }
}
