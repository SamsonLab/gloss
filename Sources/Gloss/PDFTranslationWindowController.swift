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

private final class PDFDropContainerView: NSView {
    var onDrop: (([URL]) -> Void)?

    private let dropFeedbackView = NSVisualEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func installDropFeedback() {
        dropFeedbackView.material = .hudWindow
        dropFeedbackView.blendingMode = .withinWindow
        dropFeedbackView.state = .active
        dropFeedbackView.wantsLayer = true
        dropFeedbackView.layer?.cornerRadius = 12
        dropFeedbackView.isHidden = true
        dropFeedbackView.translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView()
        imageView.image = NSImage(
            systemSymbolName: "arrow.down.doc.fill",
            accessibilityDescription: "添加 PDF"
        )
        imageView.contentTintColor = .controlAccentColor
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 24,
            weight: .medium
        )

        let title = NSTextField(labelWithString: "松开以添加 PDF")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let detail = NSTextField(labelWithString: "支持一次拖入多个文件")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [imageView, title, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        dropFeedbackView.addSubview(stack)
        addSubview(dropFeedbackView, positioned: .above, relativeTo: nil)

        NSLayoutConstraint.activate([
            dropFeedbackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            dropFeedbackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dropFeedbackView.widthAnchor.constraint(equalToConstant: 250),
            dropFeedbackView.heightAnchor.constraint(equalToConstant: 112),
            stack.centerXAnchor.constraint(equalTo: dropFeedbackView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: dropFeedbackView.centerYAnchor),
        ])
        setAccessibilityLabel("PDF 拖放区域")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !pdfURLs(from: sender.draggingPasteboard).isEmpty else { return [] }
        dropFeedbackView.isHidden = false
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        pdfURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropFeedbackView.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = pdfURLs(from: sender.draggingPasteboard)
        dropFeedbackView.isHidden = true
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        dropFeedbackView.isHidden = true
    }

    private func pdfURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls =
            pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
        return urls.filter { $0.pathExtension.lowercased() == "pdf" }
    }
}

enum PDFTranslationToolCopy {
    static func outputDescription(for outputMode: BabelDOCOutputMode) -> String {
        switch outputMode {
        case .monolingual:
            "仅输出译文 PDF，文件更轻，适合直接阅读。"
        case .bilingual:
            "保留原文与译文对照，适合核对内容。"
        }
    }

    static func outputSuffix(for outputMode: BabelDOCOutputMode) -> String {
        switch outputMode {
        case .monolingual:
            "-gloss-mono.pdf"
        case .bilingual:
            "-gloss-dual.pdf"
        }
    }

    static func outputFileName(
        for sourceURL: URL,
        outputMode: BabelDOCOutputMode
    ) -> String {
        sourceURL.deletingPathExtension().lastPathComponent
            + outputSuffix(for: outputMode)
    }

    static func timingDescription(
        timings: BabelDOCPhaseTimings,
        performance: TranslationDispatchState.DocumentPerformanceSnapshot,
        elapsedMilliseconds: Int? = nil
    ) -> String {
        var components: [String] = []
        if timings.launchingMilliseconds > 0 {
            components.append("准备 \(formattedDuration(timings.launchingMilliseconds))")
        }
        if timings.parsingMilliseconds > 0 {
            components.append("解析 \(formattedDuration(timings.parsingMilliseconds))")
        }
        if performance.completedTurns > 0 {
            components.append(
                "模型等待累计 \(formattedDuration(performance.modelWaitMilliseconds))"
            )
        } else if timings.translatingMilliseconds > 0 {
            components.append("翻译 \(formattedDuration(timings.translatingMilliseconds))")
        }
        if timings.typesettingMilliseconds > 0 {
            components.append("排版 \(formattedDuration(timings.typesettingMilliseconds))")
        }
        if timings.savingMilliseconds > 0 {
            components.append("保存 \(formattedDuration(timings.savingMilliseconds))")
        }
        if components.isEmpty, let elapsedMilliseconds {
            components.append("已用时 \(formattedDuration(elapsedMilliseconds))")
        }
        return components.joined(separator: " · ")
    }

    private static func formattedDuration(_ milliseconds: Int) -> String {
        String(format: "%.1fs", Double(max(0, milliseconds)) / 1_000)
    }
}

@MainActor
private final class PDFQueueItem {
    enum State {
        case pending
        case running
        case completed
        case failed
        case cancelled
    }

    let id = UUID()
    let sourceURL: URL
    let document: PDFDocument
    var state: State = .pending
    var targetLanguageName: String
    var outputMode: BabelDOCOutputMode = .monolingual
    var outputDirectoryURL: URL
    var outputURL: URL?
    var statusText = "等待翻译"
    var progress: Double?
    var latestProgress: BabelDOCProgressUpdate?
    var latestPerformance = TranslationDispatchState.DocumentPerformanceSnapshot()
    var translationStartedAt: Date?

    init(
        sourceURL: URL,
        document: PDFDocument,
        targetLanguageName: String,
        outputDirectoryURL: URL
    ) {
        self.sourceURL = sourceURL
        self.document = document
        self.targetLanguageName = targetLanguageName
        self.outputDirectoryURL = outputDirectoryURL
    }
}

@MainActor
private final class PDFQueueCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("PDFQueueCell")

    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 15,
            weight: .regular
        )

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .monospacedDigitSystemFont(
            ofSize: 11,
            weight: .regular
        )
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.style = .bar
        progressIndicator.controlSize = .small
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [titleLabel, detailLabel, progressIndicator])
        textStack.orientation = .vertical
        textStack.alignment = .left
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(symbolView)
        addSubview(textStack)
        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 18),
            symbolView.heightAnchor.constraint(equalToConstant: 18),
            textStack.leadingAnchor.constraint(
                equalTo: symbolView.trailingAnchor,
                constant: 9
            ),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressIndicator.widthAnchor.constraint(equalTo: textStack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with item: PDFQueueItem) {
        titleLabel.stringValue = item.sourceURL.lastPathComponent
        titleLabel.toolTip = item.sourceURL.lastPathComponent
        let pageText = "第 1 / \(item.document.pageCount) 页"
        switch item.state {
        case .pending:
            symbolView.image = NSImage(
                systemSymbolName: "doc.richtext",
                accessibilityDescription: "等待翻译"
            )
            symbolView.contentTintColor = .secondaryLabelColor
            detailLabel.stringValue = "\(pageText) · 等待"
            progressIndicator.isHidden = true
        case .running:
            symbolView.image = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath",
                accessibilityDescription: "翻译中"
            )
            symbolView.contentTintColor = .controlAccentColor
            detailLabel.stringValue = item.statusText
            progressIndicator.isHidden = false
            if let progress = item.progress {
                progressIndicator.isIndeterminate = false
                progressIndicator.doubleValue = progress
                progressIndicator.stopAnimation(nil)
            } else {
                progressIndicator.isIndeterminate = true
                progressIndicator.startAnimation(nil)
            }
        case .completed:
            symbolView.image = NSImage(
                systemSymbolName: "checkmark.circle.fill",
                accessibilityDescription: "已完成"
            )
            symbolView.contentTintColor = .systemGreen
            detailLabel.stringValue = "\(pageText) · 已完成"
            progressIndicator.isHidden = true
        case .failed:
            symbolView.image = NSImage(
                systemSymbolName: "exclamationmark.circle.fill",
                accessibilityDescription: "翻译失败"
            )
            symbolView.contentTintColor = .systemRed
            detailLabel.stringValue = item.statusText
            progressIndicator.isHidden = true
        case .cancelled:
            symbolView.image = NSImage(
                systemSymbolName: "stop.circle",
                accessibilityDescription: "已停止"
            )
            symbolView.contentTintColor = .secondaryLabelColor
            detailLabel.stringValue = "\(pageText) · 已停止"
            progressIndicator.isHidden = true
        }
    }
}

@MainActor
final class PDFTranslationWindowController: NSObject, NSWindowDelegate {
    private enum QueueRow {
        case section(String)
        case item(PDFQueueItem)
    }

    private enum ServiceState {
        case stopped
        case starting
        case ready
        case failed(String)
    }

    private let targetLanguage: () -> String
    private let bridgeToken: () -> String?
    private let translationDispatchState: TranslationDispatchState
    private let babelDOCExternalEngine = BabelDOCExternalEngine()
    private let babelDOCService = BabelDOCServiceSession()

    private let window: NSWindow
    private let queueTableView = NSTableView()
    private let pdfView = PDFView()
    private let documentTitleLabel = NSTextField(labelWithString: "未选择 PDF")
    private let pageLabel = NSTextField(labelWithString: "—")
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let statusIconView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "添加 PDF 开始批量翻译")
    private let statusDetailLabel = NSTextField(labelWithString: "")
    private let statusProgressIndicator = NSProgressIndicator()
    private let targetLanguagePopup = NSPopUpButton()
    private let outputModeControl = NSSegmentedControl(
        labels: ["只看译文", "双语对照"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let outputFolderLabel = NSTextField(labelWithString: "")
    private let modeDescriptionLabel = NSTextField(labelWithString: "")
    private let engineLabel = NSTextField(labelWithString: "")
    private let addFilesButton = NSButton(title: "添加 PDF…", target: nil, action: nil)
    private let clearCompletedButton = NSButton(
        title: "清除已完成",
        target: nil,
        action: nil
    )
    private let translateButton = NSButton(title: "开始批量翻译", target: nil, action: nil)
    private let revealResultButton = NSButton(
        title: "在 Finder 中显示",
        target: nil,
        action: nil
    )
    private let outputFolderButton = NSButton(
        title: "更改…",
        target: nil,
        action: nil
    )
    private let retranslateButton = NSButton(
        title: "重新翻译",
        target: nil,
        action: nil
    )
    private let removeTaskButton = NSButton(title: "移除任务", target: nil, action: nil)
    private let emptyStateView = NSStackView()

    private var items: [PDFQueueItem] = []
    private var rows: [QueueRow] = []
    private var selectedItemID: UUID?
    private var defaultOutputDirectoryURL =
        PDFTranslationWindowController.defaultOutputDirectory()
    private var batchTranslationTask: Task<Void, Never>?
    private var progressRefreshTask: Task<Void, Never>?
    private var serviceStartupTask: Task<Void, Never>?
    private var serviceState: ServiceState = .stopped
    private var layoutServiceBaseURL: URL?
    private var activePerformanceRunID: UUID?
    private var isUpdatingQueueSelection = false

    init(
        targetLanguage: @escaping () -> String,
        bridgeToken: @escaping () -> String?,
        translationDispatchState: TranslationDispatchState
    ) {
        self.targetLanguage = targetLanguage
        self.bridgeToken = bridgeToken
        self.translationDispatchState = translationDispatchState
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_320, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        super.init()
        configureWindow()
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        startPDFServiceIfNeeded()
        refreshInterface()
    }

    func open(_ url: URL, pageIndex requestedPageIndex: Int = 0) throws {
        let item = try addPDF(url)
        select(item)
        let pageIndex = min(
            max(0, requestedPageIndex),
            item.document.pageCount - 1
        )
        if let page = item.document.page(at: pageIndex) {
            pdfView.go(to: page)
        }
        show()
    }

    func translationConfigurationDidChange() {
        refreshInterface()
    }

    func stop() {
        serviceStartupTask?.cancel()
        serviceStartupTask = nil
        batchTranslationTask?.cancel()
        batchTranslationTask = nil
        progressRefreshTask?.cancel()
        progressRefreshTask = nil
        activePerformanceRunID = nil
        Task { await babelDOCService.stop() }
        layoutServiceBaseURL = nil
        serviceState = .stopped
    }

    func stopAndWait() async {
        serviceStartupTask?.cancel()
        serviceStartupTask = nil
        batchTranslationTask?.cancel()
        batchTranslationTask = nil
        progressRefreshTask?.cancel()
        progressRefreshTask = nil
        activePerformanceRunID = nil
        await babelDOCService.stop()
        layoutServiceBaseURL = nil
        serviceState = .stopped
    }

    func windowWillClose(_ notification: Notification) {
        stop()
    }

    private var selectedItem: PDFQueueItem? {
        guard let selectedItemID else { return nil }
        return items.first { $0.id == selectedItemID }
    }

    private var runnableItems: [PDFQueueItem] {
        items.filter { $0.state == .pending || $0.state == .failed || $0.state == .cancelled }
    }

    private var completedItems: [PDFQueueItem] {
        items.filter { $0.state == .completed }
    }

    private func configureWindow() {
        window.title = "PDF 翻译"
        window.minSize = NSSize(width: 1_050, height: 680)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setAccessibilityLabel("Gloss PDF 翻译")
        window.tabbingMode = .disallowed

        let content = PDFDropContainerView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.onDrop = { [weak self] urls in
            self?.addPDFFiles(urls)
        }
        window.contentView = content

        let sidebar = makeSidebar()
        let center = makeDocumentArea()
        let inspector = makeInspector()
        let firstSeparator = makeSeparator()
        let secondSeparator = makeSeparator()

        for view in [sidebar, firstSeparator, center, secondSeparator, inspector] {
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 260),

            firstSeparator.topAnchor.constraint(equalTo: content.topAnchor),
            firstSeparator.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            firstSeparator.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            center.topAnchor.constraint(equalTo: content.topAnchor),
            center.leadingAnchor.constraint(equalTo: firstSeparator.trailingAnchor),
            center.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            secondSeparator.topAnchor.constraint(equalTo: content.topAnchor),
            secondSeparator.leadingAnchor.constraint(equalTo: center.trailingAnchor),
            secondSeparator.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            inspector.topAnchor.constraint(equalTo: content.topAnchor),
            inspector.leadingAnchor.constraint(equalTo: secondSeparator.trailingAnchor),
            inspector.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            inspector.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            inspector.widthAnchor.constraint(equalToConstant: 330),
        ])
        content.installDropFeedback()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pdfPageChanged),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pdfScaleChanged),
            name: .PDFViewScaleChanged,
            object: pdfView
        )
        rebuildRows()
        refreshInterface()
    }

    private func makeSidebar() -> NSView {
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        addFilesButton.target = self
        addFilesButton.action = #selector(choosePDFFiles)
        addFilesButton.bezelStyle = .rounded
        addFilesButton.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: "添加 PDF"
        )
        addFilesButton.imagePosition = .imageLeading

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("queue"))
        column.resizingMask = .autoresizingMask
        queueTableView.addTableColumn(column)
        queueTableView.headerView = nil
        queueTableView.dataSource = self
        queueTableView.delegate = self
        queueTableView.style = .sourceList
        queueTableView.backgroundColor = .clear
        queueTableView.intercellSpacing = NSSize(width: 0, height: 2)
        queueTableView.setAccessibilityLabel("PDF 翻译队列")

        let scrollView = NSScrollView()
        scrollView.documentView = queueTableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        clearCompletedButton.target = self
        clearCompletedButton.action = #selector(clearCompleted)
        clearCompletedButton.bezelStyle = .inline
        clearCompletedButton.image = NSImage(
            systemSymbolName: "trash",
            accessibilityDescription: "清除已完成"
        )
        clearCompletedButton.imagePosition = .imageLeading

        let footer = NSStackView(views: [clearCompletedButton, NSView()])
        footer.orientation = .horizontal
        footer.alignment = .centerY

        let stack = NSStackView(views: [addFilesButton, scrollView, footer])
        stack.orientation = .vertical
        stack.alignment = .left
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -12),
            addFilesButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return sidebar
    }

    private func makeDocumentArea() -> NSView {
        let center = NSVisualEffectView()
        center.material = .contentBackground
        center.blendingMode = .withinWindow
        center.state = .active
        center.translatesAutoresizingMaskIntoConstraints = false

        documentTitleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        documentTitleLabel.lineBreakMode = .byTruncatingMiddle
        documentTitleLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        let previousPageButton = symbolButton(
            "chevron.left",
            description: "上一页",
            action: #selector(previousPage)
        )
        let nextPageButton = symbolButton(
            "chevron.right",
            description: "下一页",
            action: #selector(nextPage)
        )
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        pageLabel.alignment = .center
        pageLabel.textColor = .secondaryLabelColor

        let zoomOutButton = symbolButton(
            "minus",
            description: "缩小",
            action: #selector(zoomOut)
        )
        let zoomInButton = symbolButton(
            "plus",
            description: "放大",
            action: #selector(zoomIn)
        )
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        zoomLabel.alignment = .center
        zoomLabel.textColor = .secondaryLabelColor

        let pageControls = NSStackView(views: [
            previousPageButton,
            pageLabel,
            nextPageButton,
        ])
        pageControls.orientation = .horizontal
        pageControls.alignment = .centerY
        pageControls.spacing = 3

        let zoomControls = NSStackView(views: [
            zoomOutButton,
            zoomLabel,
            zoomInButton,
        ])
        zoomControls.orientation = .horizontal
        zoomControls.alignment = .centerY
        zoomControls.spacing = 3

        let toolbarRow = NSStackView(views: [
            documentTitleLabel,
            NSView(),
            pageControls,
            zoomControls,
        ])
        toolbarRow.orientation = .horizontal
        toolbarRow.alignment = .centerY
        toolbarRow.spacing = 14

        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        statusIconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 13,
            weight: .semibold
        )
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusDetailLabel.font = .monospacedDigitSystemFont(
            ofSize: 11,
            weight: .regular
        )
        statusDetailLabel.textColor = .tertiaryLabelColor
        statusDetailLabel.alignment = .right
        statusDetailLabel.lineBreakMode = .byTruncatingHead
        let statusRow = NSStackView(views: [
            statusIconView,
            statusLabel,
            NSView(),
            statusDetailLabel,
        ])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 7

        statusProgressIndicator.style = .bar
        statusProgressIndicator.controlSize = .small
        statusProgressIndicator.minValue = 0
        statusProgressIndicator.maxValue = 100
        statusProgressIndicator.isHidden = true

        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .underPageBackgroundColor
        pdfView.setAccessibilityLabel("PDF 预览")
        pdfView.translatesAutoresizingMaskIntoConstraints = false

        let previewContainer = NSView()
        previewContainer.wantsLayer = true
        previewContainer.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
        ])

        let emptyIcon = NSImageView()
        emptyIcon.image = NSImage(
            systemSymbolName: "doc.badge.plus",
            accessibilityDescription: "添加 PDF"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 38, weight: .regular)
        )
        emptyIcon.contentTintColor = .tertiaryLabelColor

        let emptyTitle = NSTextField(labelWithString: "添加 PDF 开始翻译")
        emptyTitle.font = .systemFont(ofSize: 18, weight: .semibold)
        let emptyDescription = NSTextField(
            wrappingLabelWithString: "可一次选择多个文件；Gloss 会按队列逐个保留版式并生成译文。"
        )
        emptyDescription.font = .systemFont(ofSize: 12)
        emptyDescription.textColor = .secondaryLabelColor
        emptyDescription.alignment = .center
        let emptyButton = NSButton(title: "添加 PDF…", target: self, action: #selector(choosePDFFiles))
        emptyButton.bezelStyle = .rounded
        emptyButton.controlSize = .large

        for view in [emptyIcon, emptyTitle, emptyDescription, emptyButton] {
            emptyStateView.addArrangedSubview(view)
        }
        emptyStateView.orientation = .vertical
        emptyStateView.alignment = .centerX
        emptyStateView.spacing = 10
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            emptyStateView.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            emptyDescription.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])

        let toolbarSeparator = makeSeparator(horizontal: true)
        let stack = NSStackView(views: [
            toolbarRow,
            toolbarSeparator,
            statusRow,
            statusProgressIndicator,
            previewContainer,
        ])
        stack.orientation = .vertical
        stack.alignment = .left
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        center.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: center.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: center.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: center.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: center.bottomAnchor, constant: -14),
            toolbarRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            toolbarSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusProgressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 500),
            statusIconView.widthAnchor.constraint(equalToConstant: 16),
            statusIconView.heightAnchor.constraint(equalToConstant: 16),
            pageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 82),
            zoomLabel.widthAnchor.constraint(equalToConstant: 44),
        ])
        return center
    }

    private func makeInspector() -> NSView {
        let inspector = NSVisualEffectView()
        inspector.material = .contentBackground
        inspector.blendingMode = .withinWindow
        inspector.state = .active
        inspector.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "翻译设置")
        title.font = .systemFont(ofSize: 16, weight: .semibold)

        targetLanguagePopup.removeAllItems()
        for language in TranslationLanguages.common {
            targetLanguagePopup.addItem(withTitle: language.title)
            targetLanguagePopup.lastItem?.representedObject = language.targetName
        }
        targetLanguagePopup.target = self
        targetLanguagePopup.action = #selector(targetLanguageChanged)

        outputModeControl.selectedSegment = 0
        outputModeControl.target = self
        outputModeControl.action = #selector(outputModeChanged)
        outputModeControl.setAccessibilityLabel("输出方式")

        modeDescriptionLabel.font = .systemFont(ofSize: 12)
        modeDescriptionLabel.textColor = .secondaryLabelColor
        modeDescriptionLabel.lineBreakMode = .byWordWrapping
        modeDescriptionLabel.maximumNumberOfLines = 3

        outputFolderLabel.font = .systemFont(ofSize: 12)
        outputFolderLabel.textColor = .secondaryLabelColor
        outputFolderLabel.lineBreakMode = .byTruncatingMiddle

        outputFolderButton.target = self
        outputFolderButton.action = #selector(chooseOutputFolder)
        outputFolderButton.bezelStyle = .rounded
        let folderIcon = NSImageView()
        folderIcon.image = NSImage(
            systemSymbolName: "folder",
            accessibilityDescription: "输出文件夹"
        )
        folderIcon.contentTintColor = .secondaryLabelColor
        let folderRow = NSStackView(views: [
            folderIcon,
            outputFolderLabel,
            outputFolderButton,
        ])
        folderRow.orientation = .horizontal
        folderRow.alignment = .centerY
        folderRow.spacing = 8

        engineLabel.font = .systemFont(ofSize: 11)
        engineLabel.textColor = .secondaryLabelColor
        engineLabel.lineBreakMode = .byWordWrapping
        engineLabel.maximumNumberOfLines = 2

        translateButton.target = self
        translateButton.action = #selector(primaryAction)
        translateButton.bezelStyle = .rounded
        translateButton.controlSize = .large

        revealResultButton.target = self
        revealResultButton.action = #selector(revealTranslatedPDF)
        revealResultButton.bezelStyle = .rounded

        retranslateButton.target = self
        retranslateButton.action = #selector(retranslateSelected)
        retranslateButton.bezelStyle = .inline

        removeTaskButton.target = self
        removeTaskButton.action = #selector(removeSelectedTask)
        removeTaskButton.bezelStyle = .inline
        removeTaskButton.contentTintColor = .secondaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        let settingsSeparator = makeSeparator(horizontal: true)
        let stack = NSStackView(views: [
            title,
            labeledControl("目标语言", targetLanguagePopup),
            labeledControl("输出方式", outputModeControl),
            modeDescriptionLabel,
            labeledControl("输出文件夹", folderRow),
            settingsSeparator,
            engineLabel,
            spacer,
            translateButton,
            revealResultButton,
            retranslateButton,
            removeTaskButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .left
        stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: inspector.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: inspector.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: inspector.bottomAnchor, constant: -16),
            targetLanguagePopup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            outputModeControl.widthAnchor.constraint(equalTo: stack.widthAnchor),
            folderRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            settingsSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            translateButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            revealResultButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return inspector
    }

    private func labeledControl(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.alignment = .left
        stack.spacing = 7
        return stack
    }

    private func makeSeparator(horizontal: Bool = false) -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        if horizontal {
            separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        } else {
            separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        }
        return separator
    }

    private func symbolButton(
        _ symbolName: String,
        description: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton(
            image: NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: description
            )!, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.setAccessibilityLabel(description)
        return button
    }

    @discardableResult
    private func addPDF(_ url: URL) throws -> PDFQueueItem {
        let normalizedURL = url.standardizedFileURL
        if let existing = items.first(where: {
            $0.sourceURL.standardizedFileURL == normalizedURL
        }) {
            return existing
        }
        guard let document = PDFDocument(url: url) else {
            throw PDFTranslationWindowError.cannotOpen
        }
        guard !document.isLocked else {
            throw PDFTranslationWindowError.locked
        }
        guard document.pageCount > 0 else {
            throw PDFTranslationWindowError.emptyDocument
        }
        let item = PDFQueueItem(
            sourceURL: normalizedURL,
            document: document,
            targetLanguageName: targetLanguage(),
            outputDirectoryURL: defaultOutputDirectoryURL
        )
        items.append(item)
        rebuildRows()
        return item
    }

    private func select(_ item: PDFQueueItem) {
        selectedItemID = item.id
        rebuildRows()
        if let row = rows.firstIndex(where: {
            if case .item(let candidate) = $0 { return candidate.id == item.id }
            return false
        }) {
            isUpdatingQueueSelection = true
            queueTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isUpdatingQueueSelection = false
            queueTableView.scrollRowToVisible(row)
        }
        pdfView.document = item.document
        pdfView.autoScales = true
        refreshInterface()
    }

    private func rebuildRows() {
        let active = items.filter { $0.state != .completed }
        let completed = items.filter { $0.state == .completed }
        var nextRows: [QueueRow] = []
        if !active.isEmpty {
            nextRows.append(.section("进行中"))
            nextRows.append(contentsOf: active.map(QueueRow.item))
        }
        if !completed.isEmpty {
            nextRows.append(.section("已完成"))
            nextRows.append(contentsOf: completed.map(QueueRow.item))
        }
        rows = nextRows
        queueTableView.reloadData()
        if let selectedItemID,
            let row = rows.firstIndex(where: {
                if case .item(let item) = $0 { return item.id == selectedItemID }
                return false
            })
        {
            isUpdatingQueueSelection = true
            queueTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isUpdatingQueueSelection = false
        }
    }

    private func refreshInterface() {
        let item = selectedItem
        let hasItem = item != nil
        pdfView.isHidden = !hasItem
        emptyStateView.isHidden = hasItem
        clearCompletedButton.isEnabled = !completedItems.isEmpty && batchTranslationTask == nil
        addFilesButton.isEnabled = batchTranslationTask == nil

        documentTitleLabel.stringValue = item?.sourceURL.lastPathComponent ?? "未选择 PDF"
        if let item, pdfView.document !== item.document {
            pdfView.document = item.document
            pdfView.autoScales = true
        }
        updatePageLabel()
        updateStatus(for: item)
        updateInspector(for: item)
        rebuildRows()
    }

    private func updateStatus(for item: PDFQueueItem?) {
        guard let item else {
            statusIconView.image = NSImage(
                systemSymbolName: "tray",
                accessibilityDescription: "队列为空"
            )
            statusIconView.contentTintColor = .secondaryLabelColor
            statusLabel.stringValue = "添加 PDF 开始批量翻译"
            statusDetailLabel.stringValue = ""
            statusProgressIndicator.isHidden = true
            return
        }
        statusLabel.stringValue = item.statusText
        switch item.state {
        case .pending:
            statusIconView.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "等待")
            statusIconView.contentTintColor = .secondaryLabelColor
            statusDetailLabel.stringValue = "\(item.document.pageCount) 页 · 等待"
            statusProgressIndicator.isHidden = true
        case .running:
            statusIconView.image = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath",
                accessibilityDescription: "翻译中"
            )
            statusIconView.contentTintColor = .controlAccentColor
            statusDetailLabel.stringValue = timingDescription(for: item)
            statusProgressIndicator.isHidden = false
            if let progress = item.progress {
                statusProgressIndicator.isIndeterminate = false
                statusProgressIndicator.doubleValue = progress
                statusProgressIndicator.stopAnimation(nil)
            } else {
                statusProgressIndicator.isIndeterminate = true
                statusProgressIndicator.startAnimation(nil)
            }
        case .completed:
            statusIconView.image = NSImage(
                systemSymbolName: "checkmark.circle.fill",
                accessibilityDescription: "已完成"
            )
            statusIconView.contentTintColor = .systemGreen
            statusDetailLabel.stringValue =
                item.outputURL.map {
                    "输出文件：\($0.lastPathComponent)"
                } ?? ""
            statusProgressIndicator.isHidden = true
        case .failed:
            statusIconView.image = NSImage(
                systemSymbolName: "exclamationmark.circle.fill",
                accessibilityDescription: "失败"
            )
            statusIconView.contentTintColor = .systemRed
            statusDetailLabel.stringValue = "可点击重试"
            statusProgressIndicator.isHidden = true
        case .cancelled:
            statusIconView.image = NSImage(
                systemSymbolName: "stop.circle",
                accessibilityDescription: "已停止"
            )
            statusIconView.contentTintColor = .secondaryLabelColor
            statusDetailLabel.stringValue = "可点击重新开始"
            statusProgressIndicator.isHidden = true
        }
    }

    private func updateInspector(for item: PDFQueueItem?) {
        let controlsEnabled = item != nil && item?.state != .running && batchTranslationTask == nil
        targetLanguagePopup.isEnabled = controlsEnabled
        outputModeControl.isEnabled = controlsEnabled
        outputFolderButton.isEnabled = controlsEnabled
        removeTaskButton.isEnabled = controlsEnabled

        if let item {
            selectLanguage(item.targetLanguageName)
            outputModeControl.selectedSegment = item.outputMode == .bilingual ? 1 : 0
            modeDescriptionLabel.stringValue = PDFTranslationToolCopy.outputDescription(
                for: item.outputMode
            )
            outputFolderLabel.stringValue = item.outputDirectoryURL.path
        } else {
            selectLanguage(targetLanguage())
            outputModeControl.selectedSegment = 0
            modeDescriptionLabel.stringValue = PDFTranslationToolCopy.outputDescription(
                for: .monolingual
            )
            outputFolderLabel.stringValue = defaultOutputDirectoryURL.path
        }

        engineLabel.stringValue = serviceDescription
        let runnableCount = runnableItems.count
        if batchTranslationTask != nil {
            translateButton.title = "停止批量翻译"
            translateButton.bezelColor = .systemRed
            translateButton.isEnabled = true
        } else if runnableCount > 0 {
            translateButton.title =
                runnableCount == 1
                ? "开始翻译"
                : "开始批量翻译（\(runnableCount)）"
            translateButton.bezelColor = .controlAccentColor
            translateButton.isEnabled = true
        } else if item?.outputURL != nil {
            translateButton.title = "打开译文"
            translateButton.bezelColor = .controlAccentColor
            translateButton.isEnabled = true
        } else if BabelDOCExternalEngine.resolveRuntime() == nil {
            translateButton.title = "安装 BabelDOC…"
            translateButton.bezelColor = nil
            translateButton.isEnabled = true
        } else {
            translateButton.title = "开始批量翻译"
            translateButton.bezelColor = nil
            translateButton.isEnabled = false
        }
        revealResultButton.isHidden = item?.outputURL == nil
        retranslateButton.isHidden = item?.state != .completed
        removeTaskButton.isHidden = item == nil || item?.state == .running
    }

    private var serviceDescription: String {
        let runtime = BabelDOCExternalEngine.resolveRuntime()
        return switch (runtime, serviceState) {
        case (nil, _):
            "需要安装 BabelDOC"
        case (.some(let runtime), .stopped):
            "BabelDOC · \(runtime.source) · PDF 服务未启动"
        case (.some(let runtime), .starting):
            "BabelDOC · \(runtime.source) · 正在启动常驻 PDF 服务…"
        case (.some(let runtime), .ready):
            "BabelDOC · \(runtime.source) · PDF 服务已就绪"
        case (.some(let runtime), .failed(let message)):
            "BabelDOC · \(runtime.source) · 服务回退：\(message)"
        }
    }

    private func selectLanguage(_ targetName: String) {
        if let index = targetLanguagePopup.itemArray.firstIndex(where: {
            $0.representedObject as? String == targetName
        }) {
            targetLanguagePopup.selectItem(at: index)
            return
        }
        targetLanguagePopup.addItem(withTitle: targetName)
        targetLanguagePopup.lastItem?.representedObject = targetName
        targetLanguagePopup.selectItem(at: targetLanguagePopup.numberOfItems - 1)
    }

    private func startPDFServiceIfNeeded() {
        guard serviceStartupTask == nil,
            layoutServiceBaseURL == nil,
            let runtime = BabelDOCExternalEngine.resolveRuntime()
        else { return }
        serviceState = .starting
        engineLabel.stringValue = serviceDescription
        serviceStartupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let baseURL = try await babelDOCService.start(runtime: runtime)
                guard !Task.isCancelled else { return }
                layoutServiceBaseURL = baseURL
                serviceState = .ready
            } catch is CancellationError {
                serviceState = .stopped
            } catch {
                serviceState = .failed(error.localizedDescription)
                layoutServiceBaseURL = nil
            }
            serviceStartupTask = nil
            refreshInterface()
        }
    }

    @objc private func choosePDFFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "添加"
        panel.message = "选择一个或多个要批量翻译的 PDF。"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            addPDFFiles(panel.urls)
        }
    }

    private func addPDFFiles(_ urls: [URL]) {
        var lastAdded: PDFQueueItem?
        var failures: [String] = []
        for url in urls {
            do {
                lastAdded = try addPDF(url)
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        if let lastAdded {
            select(lastAdded)
        }
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "部分 PDF 无法添加"
            alert.informativeText = failures.joined(separator: "\n")
            alert.beginSheetModal(for: window)
        }
        refreshInterface()
    }

    @objc private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL =
            selectedItem?.outputDirectoryURL
            ?? defaultOutputDirectoryURL
        panel.message = "选择译文输出文件夹。"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if let selectedItem {
                selectedItem.outputDirectoryURL = url
            } else {
                defaultOutputDirectoryURL = url
            }
            refreshInterface()
        }
    }

    @objc private func targetLanguageChanged() {
        guard let selectedItem,
            let value = targetLanguagePopup.selectedItem?.representedObject as? String
        else { return }
        selectedItem.targetLanguageName = value
        selectedItem.statusText = "等待翻译"
        if selectedItem.state == .completed {
            selectedItem.state = .pending
            selectedItem.outputURL = nil
        }
        refreshInterface()
    }

    @objc private func outputModeChanged() {
        guard let selectedItem else { return }
        let mode: BabelDOCOutputMode =
            outputModeControl.selectedSegment == 1
            ? .bilingual
            : .monolingual
        guard selectedItem.outputMode != mode else { return }
        selectedItem.outputMode = mode
        selectedItem.statusText = "等待翻译"
        if selectedItem.state == .completed {
            selectedItem.state = .pending
            selectedItem.outputURL = nil
        }
        refreshInterface()
    }

    @objc private func primaryAction() {
        if let batchTranslationTask {
            batchTranslationTask.cancel()
            return
        }
        if !runnableItems.isEmpty {
            beginBatchTranslation()
            return
        }
        if let outputURL = selectedItem?.outputURL {
            NSWorkspace.shared.open(outputURL)
            return
        }
        if BabelDOCExternalEngine.resolveRuntime() == nil {
            showBabelDOCInstallationHelp()
        }
    }

    private func beginBatchTranslation() {
        guard let runtime = BabelDOCExternalEngine.resolveRuntime() else {
            showBabelDOCInstallationHelp()
            return
        }
        guard let token = bridgeToken() else {
            showAlert(
                title: "翻译服务尚未就绪",
                message: "Gloss 本地翻译桥接仍在启动，请稍后再试。"
            )
            return
        }
        let queue = runnableItems
        guard !queue.isEmpty else { return }
        batchTranslationTask = Task { [weak self] in
            guard let self else { return }
            if layoutServiceBaseURL == nil {
                startPDFServiceIfNeeded()
                await serviceStartupTask?.value
            }
            for item in queue {
                guard !Task.isCancelled else { break }
                await translate(item, runtime: runtime, bridgeToken: token)
            }
            batchTranslationTask = nil
            activePerformanceRunID = nil
            progressRefreshTask?.cancel()
            progressRefreshTask = nil
            refreshInterface()
        }
        refreshInterface()
    }

    private func translate(
        _ item: PDFQueueItem,
        runtime: BabelDOCRuntimeLaunch,
        bridgeToken: String
    ) async {
        guard
            let targetLanguageCode = TranslationLanguages.babelDOCCode(
                forTargetName: item.targetLanguageName
            )
        else {
            item.state = .failed
            item.statusText = "BabelDOC 暂不支持当前目标语言"
            refreshInterface()
            return
        }

        item.state = .running
        item.outputURL = nil
        item.progress = nil
        item.latestProgress = nil
        item.latestPerformance = .init()
        item.translationStartedAt = Date()
        item.statusText =
            layoutServiceBaseURL == nil
            ? "正在启动 BabelDOC…"
            : "正在连接常驻 PDF 服务…"
        select(item)
        refreshInterface()

        let runID = UUID()
        activePerformanceRunID = runID
        startProgressRefresh(for: item, runID: runID)
        await translationDispatchState.beginDocumentPerformanceRun(id: runID)
        let temporaryOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Gloss-BabelDOC-\(UUID().uuidString)",
                isDirectory: true
            )
        let sampledPageTexts = (0..<min(5, item.document.pageCount)).map {
            item.document.page(at: $0)?.string
        }
        let sourceText = sampledPageTexts.compactMap { $0 }.joined(separator: "\n")
        let detectedSource =
            TranslationLanguages.detectedSourceLanguageCode(
                in: sourceText
            ) ?? "en"
        let destination = destinationURL(for: item)
        var completedTimings: BabelDOCPhaseTimings?

        defer {
            try? FileManager.default.removeItem(at: temporaryOutput)
        }
        do {
            let result = try await babelDOCExternalEngine.translate(
                BabelDOCTranslationRequest(
                    inputURL: item.sourceURL,
                    outputDirectory: temporaryOutput,
                    sourceLanguageCode: babelDOCSourceCode(detectedSource),
                    targetLanguageCode: targetLanguageCode,
                    bridgeBaseURL: URL(string: "http://127.0.0.1:8787/v1")!,
                    bridgeToken: bridgeToken,
                    qps: 8,
                    maximumPagesPerPart: Self.babelDOCMaximumPagesPerPart(),
                    skipScannedDetection: BabelDOCExternalEngine.hasReliableTextLayer(
                        sampledPageTexts
                    ),
                    outputMode: item.outputMode,
                    layoutServiceBaseURL: layoutServiceBaseURL
                ),
                runtime: runtime,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        await self?.showProgress(progress, for: item.id, runID: runID)
                    }
                }
            )
            completedTimings = result.timings
            try Task.checkCancellation()
            let generated =
                item.outputMode == .monolingual
                ? result.monolingualPDF
                : result.bilingualPDF
            guard let generated else {
                throw BabelDOCExternalEngineError.outputMissing
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try copyReplacing(generated, to: destination)
            item.outputURL = destination
            item.state = .completed
            item.progress = 100
            item.statusText = "已完成"
        } catch is CancellationError {
            item.state = .cancelled
            item.progress = nil
            item.statusText = "已停止"
        } catch {
            item.state = .failed
            item.progress = nil
            item.statusText = error.localizedDescription
        }

        let performance = await translationDispatchState.endDocumentPerformanceRun(
            id: runID
        )
        if let performance {
            item.latestPerformance = performance
        }
        if let completedTimings, let performance {
            let wallMilliseconds =
                item.translationStartedAt.map {
                    Int(Date().timeIntervalSince($0) * 1_000)
                } ?? 0
            GlossRuntimeLog.shared.write(
                "pdf",
                "translation_complete file=\(item.sourceURL.lastPathComponent) mode=\(item.outputMode.rawValue) wall_ms=\(wallMilliseconds) launching_ms=\(completedTimings.launchingMilliseconds) parsing_ms=\(completedTimings.parsingMilliseconds) translating_ms=\(completedTimings.translatingMilliseconds) typesetting_ms=\(completedTimings.typesettingMilliseconds) saving_ms=\(completedTimings.savingMilliseconds) model_prepare_ms=\(performance.preparationMilliseconds) model_wait_ms=\(performance.modelWaitMilliseconds) model_output_stream_ms=\(performance.outputStreamMilliseconds) model_turn_ms=\(performance.totalTurnMilliseconds) model_turns=\(performance.completedTurns) persistent_layout=\(layoutServiceBaseURL != nil)"
            )
        }
        if activePerformanceRunID == runID {
            activePerformanceRunID = nil
            progressRefreshTask?.cancel()
            progressRefreshTask = nil
        }
        rebuildRows()
        refreshInterface()
    }

    private func destinationURL(for item: PDFQueueItem) -> URL {
        let fileName = PDFTranslationToolCopy.outputFileName(
            for: item.sourceURL,
            outputMode: item.outputMode
        )
        let candidate = item.outputDirectoryURL.appendingPathComponent(fileName)
        let reserved = Set(
            items.compactMap { candidateItem -> String? in
                guard candidateItem.id != item.id else { return nil }
                return candidateItem.outputURL?.standardizedFileURL.path
            })
        guard reserved.contains(candidate.standardizedFileURL.path) else {
            return candidate
        }
        let base = candidate.deletingPathExtension().lastPathComponent
        for index in 2...999 {
            let alternate = item.outputDirectoryURL.appendingPathComponent(
                "\(base)-\(index).pdf"
            )
            if !reserved.contains(alternate.standardizedFileURL.path) {
                return alternate
            }
        }
        return item.outputDirectoryURL.appendingPathComponent(
            "\(base)-\(UUID().uuidString).pdf"
        )
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

    private func startProgressRefresh(for item: PDFQueueItem, runID: UUID) {
        progressRefreshTask?.cancel()
        progressRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                guard let self, activePerformanceRunID == runID else { return }
                if let performance =
                    await translationDispatchState
                    .documentPerformanceSnapshot(for: runID)
                {
                    item.latestPerformance = performance
                }
                if selectedItemID == item.id {
                    updateStatus(for: item)
                }
            }
        }
    }

    private func showProgress(
        _ progress: BabelDOCProgressUpdate,
        for itemID: UUID,
        runID: UUID
    ) async {
        guard activePerformanceRunID == runID,
            let item = items.first(where: { $0.id == itemID })
        else { return }
        item.latestProgress = progress
        item.progress =
            progress.phase == .launching
            ? nil
            : max(1, progress.overallProgress)
        if let performance =
            await translationDispatchState
            .documentPerformanceSnapshot(for: runID)
        {
            item.latestPerformance = performance
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
        item.statusText =
            switch progress.phase {
            case .launching:
                layoutServiceBaseURL == nil ? "正在启动 BabelDOC…" : "PDF 服务已就绪，正在准备任务…"
            case .parsing:
                "正在解析页面与版面 · \(percent)%\(part)"
            case .translating:
                "模型正在翻译 · \(percent)%\(part)"
            case .typesetting:
                "正在排版并恢复原始样式 · \(percent)%\(part)"
            case .saving:
                "正在生成 PDF · \(percent)%\(part)"
            case .finalizing:
                "正在整理输出文件 · \(percent)%"
            case .completed:
                "BabelDOC 处理完成，正在保存…"
            }
        rebuildRows()
        if selectedItemID == itemID {
            updateStatus(for: item)
        }
    }

    private func timingDescription(for item: PDFQueueItem) -> String {
        let timings = item.latestProgress?.timings ?? BabelDOCPhaseTimings()
        return PDFTranslationToolCopy.timingDescription(
            timings: timings,
            performance: item.latestPerformance,
            elapsedMilliseconds: item.translationStartedAt.map {
                Int(Date().timeIntervalSince($0) * 1_000)
            }
        )
    }

    @objc private func retranslateSelected() {
        guard let selectedItem, selectedItem.state == .completed else { return }
        selectedItem.state = .pending
        selectedItem.outputURL = nil
        selectedItem.progress = nil
        selectedItem.statusText = "等待重新翻译"
        refreshInterface()
    }

    @objc private func revealTranslatedPDF() {
        guard let outputURL = selectedItem?.outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
    }

    @objc private func removeSelectedTask() {
        guard let selectedItem, selectedItem.state != .running else { return }
        items.removeAll { $0.id == selectedItem.id }
        selectedItemID = items.first?.id
        if let first = items.first {
            select(first)
        } else {
            pdfView.document = nil
            rebuildRows()
            refreshInterface()
        }
    }

    @objc private func clearCompleted() {
        let removedIDs = Set(completedItems.map(\.id))
        items.removeAll { removedIDs.contains($0.id) }
        if let selectedItemID, removedIDs.contains(selectedItemID) {
            self.selectedItemID = items.first?.id
            if let first = items.first {
                select(first)
            } else {
                pdfView.document = nil
            }
        }
        rebuildRows()
        refreshInterface()
    }

    @objc private func previousPage() {
        pdfView.goToPreviousPage(nil)
    }

    @objc private func nextPage() {
        pdfView.goToNextPage(nil)
    }

    @objc private func zoomOut() {
        pdfView.autoScales = false
        pdfView.scaleFactor = max(pdfView.minScaleFactor, pdfView.scaleFactor / 1.15)
        updateZoomLabel()
    }

    @objc private func zoomIn() {
        pdfView.autoScales = false
        pdfView.scaleFactor = min(pdfView.maxScaleFactor, pdfView.scaleFactor * 1.15)
        updateZoomLabel()
    }

    @objc private func pdfPageChanged() {
        updatePageLabel()
    }

    @objc private func pdfScaleChanged() {
        updateZoomLabel()
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
        updateZoomLabel()
    }

    private func updateZoomLabel() {
        guard pdfView.document != nil else {
            zoomLabel.stringValue = "—"
            return
        }
        zoomLabel.stringValue = "\(Int((pdfView.scaleFactor * 100).rounded()))%"
    }

    private func showBabelDOCInstallationHelp() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "需要安装 BabelDOC"
        alert.informativeText = """
            PDF 翻译使用独立安装的 BabelDOC。

            安装命令：
            uv tool install --python 3.12 BabelDOC

            也可以通过 GLOSS_BABELDOC_BIN 指定可执行文件。
            """
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window)
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

    nonisolated private static func defaultOutputDirectory() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
    }
}

extension PDFTranslationWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .section(let title):
            let identifier = NSUserInterfaceItemIdentifier("PDFQueueSection")
            let cell =
                tableView.makeView(withIdentifier: identifier, owner: self)
                as? NSTableCellView ?? NSTableCellView()
            cell.identifier = identifier
            if cell.textField == nil {
                let label = NSTextField(labelWithString: "")
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = .secondaryLabelColor
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.textField = label
                cell.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            cell.textField?.stringValue = title
            return cell
        case .item(let item):
            let cell =
                tableView.makeView(
                    withIdentifier: PDFQueueCellView.identifier,
                    owner: self
                ) as? PDFQueueCellView ?? PDFQueueCellView()
            cell.configure(with: item)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .section = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 54 }
        if case .section = rows[row] { return 28 }
        return 58
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .item = rows[row] { return true }
        return false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingQueueSelection else { return }
        let row = queueTableView.selectedRow
        guard rows.indices.contains(row), case .item(let item) = rows[row] else {
            return
        }
        selectedItemID = item.id
        pdfView.document = item.document
        pdfView.autoScales = true
        refreshInterface()
    }
}
