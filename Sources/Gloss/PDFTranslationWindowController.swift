import AppKit
import GlossCore
import GlossOCR
import PDFKit
import UniformTypeIdentifiers

private enum PDFTranslationWindowError: LocalizedError {
    case cannotOpen
    case locked
    case emptyDocument
    case pageUnavailable(Int)
    case cannotRenderPage(Int)
    case cannotExportPage(Int)

    var errorDescription: String? {
        switch self {
        case .cannotOpen:
            "无法打开这个 PDF。"
        case .locked:
            "这个 PDF 受密码保护，Gloss 暂时无法翻译。"
        case .emptyDocument:
            "这个 PDF 没有可读取的页面。"
        case .pageUnavailable(let page):
            "无法读取第 \(page) 页。"
        case .cannotRenderPage(let page):
            "无法为第 \(page) 页生成 OCR 图像。"
        case .cannotExportPage(let page):
            "无法生成第 \(page) 页的译文 PDF。"
        }
    }
}

@MainActor
final class PDFTranslationWindowController: NSObject, NSWindowDelegate {
    private enum PageState {
        case idle
        case extracting
        case recognizing
        case translating(completed: Int, total: Int)
        case complete
        case failed(String)
    }

    private let broker: TranslationBroker
    private let translationStore: DocumentTranslationStore
    private let targetLanguage: () -> String
    private let profile: () -> TranslationProfile
    private let providerRevision: () -> String

    private let window: NSWindow
    private let pdfView = PDFView()
    private let translationTextView = NSTextView()
    private let translatedPageView = PDFTranslatedPageView()
    private let translationScroll = NSScrollView()
    private let viewModeControl = NSSegmentedControl(
        labels: ["版式", "文本"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let fileLabel = NSTextField(labelWithString: "PDF 翻译")
    private let statusLabel = NSTextField(labelWithString: "选择一个 PDF 开始")
    private let pageLabel = NSTextField(labelWithString: "—")
    private let progressIndicator = NSProgressIndicator()
    private let translateAllButton = NSButton(title: "翻译全文", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)
    private let exportButton = NSButton(title: "导出译文 PDF…", target: nil, action: nil)

    private var documentURL: URL?
    private var documentDigest: String?
    private var pageBlocks: [Int: [DocumentBlock]] = [:]
    private var pageStates: [Int: PageState] = [:]
    private var translations: [String: String] = [:]
    private var pageRanges: [Int: NSRange] = [:]
    private var currentPageIndex = 0
    private var fullDocumentMode = false
    private var pendingScrollPage: Int?
    private var preparationTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var pageChangeTask: Task<Void, Never>?

    init(
        broker: TranslationBroker,
        translationStore: DocumentTranslationStore,
        targetLanguage: @escaping () -> String,
        profile: @escaping () -> TranslationProfile,
        providerRevision: @escaping () -> String
    ) {
        self.broker = broker
        self.translationStore = translationStore
        self.targetLanguage = targetLanguage
        self.profile = profile
        self.providerRevision = providerRevision
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        super.init()
        configureWindow()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        documentDigest = nil
        pageBlocks = [:]
        pageStates = [:]
        translations = [:]
        pageRanges = [:]
        currentPageIndex = min(max(0, requestedPageIndex), document.pageCount - 1)
        fullDocumentMode = false
        pendingScrollPage = currentPageIndex

        pdfView.document = document
        if let requestedPage = document.page(at: currentPageIndex) {
            pdfView.go(to: requestedPage)
        }
        fileLabel.stringValue = url.lastPathComponent
        window.title = "\(url.lastPathComponent) — Gloss"
        pageLabel.stringValue = "第 \(currentPageIndex + 1) / \(document.pageCount) 页"
        statusLabel.stringValue = "正在准备文档…"
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)
        translateAllButton.isEnabled = false
        stopButton.isEnabled = true
        exportButton.isEnabled = false
        rebuildTranslationView()

        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let digest = try await Task.detached(priority: .utility) {
                    try DocumentDigest.file(at: url)
                }.value
                try Task.checkCancellation()
                guard documentURL == url else { return }
                documentDigest = digest
                translateAllButton.isEnabled = true
                statusLabel.stringValue = "正在翻译当前页"
                scheduleTranslation(for: currentPageIndex, immediate: true)
            } catch is CancellationError {
                return
            } catch {
                guard documentURL == url else { return }
                finishRunning()
                statusLabel.stringValue = error.localizedDescription
            }
        }
    }

    func translationConfigurationDidChange() {
        guard documentURL != nil, documentDigest != nil else { return }
        translationTask?.cancel()
        pageChangeTask?.cancel()
        translations = [:]
        pageStates = pageBlocks.keys.reduce(into: [:]) { $0[$1] = .idle }
        fullDocumentMode = false
        pendingScrollPage = currentPageIndex
        rebuildTranslationView()
        statusLabel.stringValue = "翻译配置已更新"
        scheduleTranslation(for: currentPageIndex, immediate: true)
    }

    func stop() {
        preparationTask?.cancel()
        translationTask?.cancel()
        pageChangeTask?.cancel()
        preparationTask = nil
        translationTask = nil
        pageChangeTask = nil
        finishRunning()
    }

    func windowWillClose(_ notification: Notification) {
        stop()
    }

    func windowDidResize(_ notification: Notification) {
        updateTranslatedPageView()
        if viewModeControl.selectedSegment == 1 {
            resizeTranslationTextView()
        }
    }

    private func configureWindow() {
        window.title = "PDF 翻译 — Gloss"
        window.minSize = NSSize(width: 860, height: 560)
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
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleStack = NSStackView(views: [fileLabel, statusLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2

        pageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        pageLabel.textColor = .secondaryLabelColor

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true

        translateAllButton.target = self
        translateAllButton.action = #selector(translateEntireDocument)
        translateAllButton.bezelStyle = .rounded

        stopButton.target = self
        stopButton.action = #selector(stopTranslation)
        stopButton.bezelStyle = .rounded
        stopButton.isEnabled = false

        viewModeControl.selectedSegment = 0
        viewModeControl.target = self
        viewModeControl.action = #selector(translationViewModeChanged)
        viewModeControl.setToolTip("保留页面版式", forSegment: 0)
        viewModeControl.setToolTip("查看提取后的原文与译文", forSegment: 1)

        exportButton.target = self
        exportButton.action = #selector(exportTranslatedPDF)
        exportButton.bezelStyle = .rounded
        exportButton.isEnabled = false

        let headerStack = NSStackView(views: [
            titleStack,
            NSView(),
            pageLabel,
            progressIndicator,
            viewModeControl,
            translateAllButton,
            stopButton,
            exportButton,
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

        translationTextView.isEditable = false
        translationTextView.isSelectable = true
        translationTextView.isRichText = true
        translationTextView.drawsBackground = true
        translationTextView.backgroundColor = .textBackgroundColor
        translationTextView.textContainerInset = NSSize(width: 26, height: 24)
        translationTextView.textContainer?.widthTracksTextView = true
        translationTextView.isHorizontallyResizable = false
        translationTextView.isVerticallyResizable = true
        translationTextView.autoresizingMask = [.width]

        translationScroll.documentView = translatedPageView
        translationScroll.hasVerticalScroller = true
        translationScroll.hasHorizontalScroller = false
        translationScroll.autohidesScrollers = true
        translationScroll.borderType = .noBorder

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(pdfView)
        splitView.addArrangedSubview(translationScroll)

        content.addSubview(header)
        content.addSubview(splitView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 60),

            headerStack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18),
            headerStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -18),
            headerStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            splitView.topAnchor.constraint(equalTo: header.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            pdfView.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            translationScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pdfPageChanged),
            name: .PDFViewPageChanged,
            object: pdfView
        )

        DispatchQueue.main.async {
            splitView.setPosition(670, ofDividerAt: 0)
        }
    }

    @objc private func pdfPageChanged() {
        guard let document = pdfView.document,
            let page = pdfView.currentPage
        else { return }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }

        currentPageIndex = index
        pageLabel.stringValue = "第 \(index + 1) / \(document.pageCount) 页"
        pendingScrollPage = index
        rebuildTranslationView()
        scheduleTranslation(for: index)
    }

    @objc private func translateEntireDocument() {
        guard pdfView.document != nil, documentDigest != nil else { return }
        fullDocumentMode = true
        translateAllButton.isEnabled = false
        statusLabel.stringValue = "正在翻译全文；当前页优先"
        scheduleTranslation(for: currentPageIndex, immediate: true)
    }

    @objc private func stopTranslation() {
        translationTask?.cancel()
        pageChangeTask?.cancel()
        translationTask = nil
        pageChangeTask = nil
        fullDocumentMode = false
        statusLabel.stringValue = "已停止；已有译文已保留"
        finishRunning()
    }

    @objc private func translationViewModeChanged() {
        if viewModeControl.selectedSegment == 0 {
            translationScroll.documentView = translatedPageView
            updateTranslatedPageView()
            translationScroll.contentView.scroll(to: .zero)
        } else {
            translationScroll.documentView = translationTextView
            resizeTranslationTextView()
            pendingScrollPage = currentPageIndex
            rebuildTranslationView()
        }
        translationScroll.reflectScrolledClipView(translationScroll.contentView)
    }

    @objc private func exportTranslatedPDF() {
        guard let documentURL, let document = pdfView.document else { return }
        guard completedPageCount() == document.pageCount else {
            statusLabel.stringValue = "请先完成全文翻译再导出 PDF"
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue =
            documentURL.deletingPathExtension().lastPathComponent + "-gloss.pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            do {
                statusLabel.stringValue = "正在生成保留版式的译文 PDF…"
                let output = PDFDocument()
                for pageIndex in 0..<document.pageCount {
                    guard let page = document.page(at: pageIndex) else {
                        throw PDFTranslationWindowError.pageUnavailable(pageIndex + 1)
                    }
                    let renderer = PDFTranslatedPageView()
                    renderer.update(
                        page: page,
                        blocks: pageBlocks[pageIndex] ?? [],
                        translations: translations,
                        availableWidth: page.bounds(for: .mediaBox).width,
                        pageInset: 0
                    )
                    let data = renderer.dataWithPDF(inside: renderer.bounds)
                    guard let renderedDocument = PDFDocument(data: data),
                        let renderedPage = renderedDocument.page(at: 0)
                    else {
                        throw PDFTranslationWindowError.cannotExportPage(pageIndex + 1)
                    }
                    output.insert(renderedPage, at: pageIndex)
                }
                guard output.write(to: destination) else {
                    throw PDFTranslationWindowError.cannotExportPage(document.pageCount)
                }
                statusLabel.stringValue = "已导出 \(destination.lastPathComponent)"
            } catch {
                statusLabel.stringValue = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    private func scheduleTranslation(for pageIndex: Int, immediate: Bool = false) {
        guard documentDigest != nil else { return }
        pageChangeTask?.cancel()
        pageChangeTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(180))
            }
            guard !Task.isCancelled, let self else { return }
            startTranslationSequence(at: pageIndex)
        }
    }

    private func startTranslationSequence(at pageIndex: Int) {
        guard let document = pdfView.document else { return }
        translationTask?.cancel()
        let pages = translationOrder(
            startingAt: pageIndex,
            pageCount: document.pageCount,
            includeEntireDocument: fullDocumentMode
        )

        stopButton.isEnabled = true
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        translationTask = Task { [weak self] in
            guard let self else { return }
            await runTranslationSequence(pages)
        }
    }

    private func runTranslationSequence(_ pages: [Int]) async {
        defer {
            if !Task.isCancelled {
                finishRunning()
            }
        }

        for (offset, pageIndex) in pages.enumerated() {
            do {
                try Task.checkCancellation()
                if case .complete = pageStates[pageIndex] {
                    continue
                }
                let priority: TranslationPriority = offset == 0 ? .visible : .background
                try await translatePage(pageIndex, priority: priority)
            } catch is CancellationError {
                return
            } catch {
                pageStates[pageIndex] = .failed(error.localizedDescription)
                rebuildTranslationView()
                if offset == 0 {
                    statusLabel.stringValue =
                        "第 \(pageIndex + 1) 页失败：\(error.localizedDescription)"
                }
            }
        }

        let completePages = completedPageCount()
        if let document = pdfView.document, completePages == document.pageCount {
            statusLabel.stringValue = "全文翻译完成"
            translateAllButton.title = "全文已完成"
            translateAllButton.isEnabled = false
        } else {
            statusLabel.stringValue = "当前页及后续页面已预热"
            translateAllButton.title = "翻译全文"
            translateAllButton.isEnabled = true
        }
    }

    private func translatePage(
        _ pageIndex: Int,
        priority: TranslationPriority
    ) async throws {
        guard let document = pdfView.document,
            let digest = documentDigest
        else {
            throw PDFTranslationWindowError.cannotOpen
        }

        let blocks: [DocumentBlock]
        if let existing = pageBlocks[pageIndex] {
            blocks = existing
        } else {
            blocks = try await extractBlocks(pageIndex, from: document)
            pageBlocks[pageIndex] = blocks
        }
        guard !blocks.isEmpty else {
            throw TranslationError.emptyInput
        }

        let targetLanguage = targetLanguage()
        let profile = profile()
        let providerRevision = providerRevision()
        let keysByID = Dictionary(
            uniqueKeysWithValues: blocks.map { block in
                (
                    block.id,
                    DocumentTranslationCacheKey(
                        documentDigest: digest,
                        pageIndex: block.pageIndex,
                        blockIndex: block.blockIndex,
                        sourceDigest: block.sourceDigest,
                        targetLanguage: targetLanguage,
                        profile: profile,
                        providerRevision: providerRevision
                    )
                )
            }
        )
        let translatableBlocks = blocks.filter(isTranslatableDocumentBlock)

        let cachedKeys = translatableBlocks.compactMap { keysByID[$0.id] }
        let cached = try await translationStore.values(for: cachedKeys)
        for block in translatableBlocks {
            if let key = keysByID[block.id], let value = cached[key] {
                translations[block.id] = value
            }
        }
        rebuildTranslationView()

        let missing = translatableBlocks.filter { translations[$0.id] == nil }
        guard !missing.isEmpty else {
            pageStates[pageIndex] = .complete
            rebuildTranslationView()
            updateProgressStatus()
            return
        }

        var completed = translatableBlocks.count - missing.count
        pageStates[pageIndex] = .translating(
            completed: completed,
            total: translatableBlocks.count
        )
        rebuildTranslationView()

        for batch in batches(from: missing) {
            try Task.checkCancellation()
            let request = TranslationBatchRequest(
                items: batch.map { TranslationItem(id: $0.id, text: $0.sourceText) },
                targetLanguage: targetLanguage,
                profile: profile,
                contentKind: .document,
                context: documentContext(pageIndex: pageIndex, pageCount: document.pageCount),
                priority: priority
            )
            var records: [DocumentTranslationCacheKey: String] = [:]
            for try await output in broker.translationStream(request) {
                try Task.checkCancellation()
                translations[output.id] = output.text
                if let key = keysByID[output.id] {
                    records[key] = output.text
                }
                completed += 1
                pageStates[pageIndex] = .translating(
                    completed: min(completed, translatableBlocks.count),
                    total: translatableBlocks.count
                )
                rebuildTranslationView()
            }
            try await translationStore.record(records)
        }

        pageStates[pageIndex] = .complete
        rebuildTranslationView()
        updateProgressStatus()
    }

    private func extractBlocks(
        _ pageIndex: Int,
        from document: PDFDocument
    ) async throws -> [DocumentBlock] {
        guard let page = document.page(at: pageIndex) else {
            throw PDFTranslationWindowError.pageUnavailable(pageIndex + 1)
        }

        pageStates[pageIndex] = .extracting
        rebuildTranslationView()

        let embeddedText =
            page.string?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isUsableEmbeddedText(embeddedText) {
            let lines =
                page.selection(for: page.bounds(for: .cropBox))?
                .selectionsByLine()
                .compactMap { selection -> DocumentLine? in
                    guard
                        let text = selection.string?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                        !text.isEmpty
                    else { return nil }
                    return DocumentLine(
                        text: text,
                        bounds: selection.bounds(for: page)
                    )
                } ?? []
            let positionedBlocks = DocumentBlockSegmenter.blocks(
                from: lines,
                pageIndex: pageIndex,
                source: .embeddedText
            )
            if !positionedBlocks.isEmpty {
                return positionedBlocks
            }
            return DocumentBlockSegmenter.blocks(
                from: embeddedText,
                pageIndex: pageIndex,
                source: .embeddedText
            )
        }

        pageStates[pageIndex] = .recognizing
        rebuildTranslationView()
        guard let image = renderedImage(for: page) else {
            throw PDFTranslationWindowError.cannotRenderPage(pageIndex + 1)
        }
        let regions = try await OCRTextRecognizer.recognizeRegions(image)
        let pageBounds = page.bounds(for: .mediaBox)
        let lines =
            regions
            .filter { $0.confidence >= 0.15 }
            .sorted {
                if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 {
                    return $0.boundingBox.midY > $1.boundingBox.midY
                }
                return $0.boundingBox.minX < $1.boundingBox.minX
            }
            .map { region in
                DocumentLine(
                    text: region.text,
                    bounds: CGRect(
                        x: pageBounds.minX + region.boundingBox.minX * pageBounds.width,
                        y: pageBounds.minY + region.boundingBox.minY * pageBounds.height,
                        width: region.boundingBox.width * pageBounds.width,
                        height: region.boundingBox.height * pageBounds.height
                    )
                )
            }
        let positionedBlocks = DocumentBlockSegmenter.blocks(
            from: lines,
            pageIndex: pageIndex,
            source: .ocr
        )
        if !positionedBlocks.isEmpty {
            return positionedBlocks
        }
        let recognizedText = try OCRTextLayout.orderedText(from: regions)
        return DocumentBlockSegmenter.blocks(
            from: recognizedText,
            pageIndex: pageIndex,
            source: .ocr
        )
    }

    private func renderedImage(for page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(3, max(1.5, 2_200 / bounds.width))
        let size = NSSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        let image = page.thumbnail(of: size, for: .mediaBox)
        var proposedRect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

    private func isUsableEmbeddedText(_ text: String) -> Bool {
        text.unicodeScalars.lazy
            .filter { CharacterSet.alphanumerics.contains($0) }
            .prefix(12)
            .count >= 12
    }

    private func translationOrder(
        startingAt pageIndex: Int,
        pageCount: Int,
        includeEntireDocument: Bool
    ) -> [Int] {
        guard pageCount > 0 else { return [] }
        let pageIndex = min(max(0, pageIndex), pageCount - 1)
        if includeEntireDocument {
            return Array(pageIndex..<pageCount) + Array(0..<pageIndex)
        }
        return (pageIndex...min(pageIndex + 2, pageCount - 1)).map { $0 }
    }

    private func batches(from blocks: [DocumentBlock]) -> [[DocumentBlock]] {
        var result: [[DocumentBlock]] = []
        var current: [DocumentBlock] = []
        var currentCharacters = 0

        for block in blocks {
            if !current.isEmpty,
                current.count >= 8 || currentCharacters + block.sourceText.count > 6_000
            {
                result.append(current)
                current = []
                currentCharacters = 0
            }
            current.append(block)
            currentCharacters += block.sourceText.count
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private func isTranslatableDocumentBlock(_ block: DocumentBlock) -> Bool {
        let text = block.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 2 else {
            return false
        }

        let lowercased = text.lowercased()
        if text.contains("@")
            || lowercased.contains("http://")
            || lowercased.contains("https://")
            || lowercased.contains("doi:")
            || lowercased.contains("orcid")
        {
            return false
        }

        let mathCharacters = text.filter { "=∑∏√∫≤≥≈≠±×÷→←∂λμσ∆∇".contains($0) }.count
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        if mathCharacters >= 2, letters * 2 < text.count {
            return false
        }
        if block.pageIndex == 0,
            text.count < 160,
            medianLineHeight(for: block) < 13,
            looksLikeAuthorMetadata(text)
        {
            return false
        }
        return true
    }

    private func medianLineHeight(for block: DocumentBlock) -> CGFloat {
        let heights = block.boundingRects.map(\.height).filter { $0 > 0 }.sorted()
        return heights.isEmpty ? 0 : heights[heights.count / 2]
    }

    private func looksLikeAuthorMetadata(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        if ["university", "research", "institute", "laboratory", "google brain"]
            .contains(where: lowercased.contains)
        {
            return true
        }

        let words = text.split(whereSeparator: \.isWhitespace)
            .map {
                $0.trimmingCharacters(
                    in: CharacterSet.letters.inverted
                )
            }
            .filter { !$0.isEmpty }
        guard (2...8).contains(words.count) else { return false }
        return words.allSatisfy { word in
            guard let first = word.unicodeScalars.first else { return false }
            return CharacterSet.uppercaseLetters.contains(first)
        }
    }

    private func documentContext(pageIndex: Int, pageCount: Int) -> String {
        let name = documentURL?.lastPathComponent ?? "PDF"
        return [
            "Document: \(name). Page \(pageIndex + 1) of \(pageCount).",
            "Preserve terminology, citations, headings, list structure,",
            "and logical relationships across the page.",
        ].joined(separator: " ")
    }

    private func rebuildTranslationView() {
        let output = NSMutableAttributedString()
        var ranges: [Int: NSRange] = [:]
        let sortedPages = Set(pageBlocks.keys)
            .union(pageStates.keys)
            .sorted()

        if sortedPages.isEmpty {
            append(
                "原始 PDF 会显示在左侧。\n\nGloss 将优先翻译当前页，并预热后续两页；扫描页会自动使用本机 OCR。",
                to: output,
                font: .systemFont(ofSize: 15),
                color: .secondaryLabelColor,
                spacingAfter: 12
            )
        }

        for pageIndex in sortedPages {
            let pageStart = output.length
            append(
                "第 \(pageIndex + 1) 页",
                to: output,
                font: .systemFont(ofSize: 20, weight: .bold),
                color: pageIndex == currentPageIndex ? .controlAccentColor : .labelColor,
                spacingAfter: 5
            )

            if let state = pageStates[pageIndex] {
                append(
                    pageStatus(state),
                    to: output,
                    font: .systemFont(ofSize: 11, weight: .medium),
                    color: statusColor(state),
                    spacingAfter: 16
                )
            }

            for block in pageBlocks[pageIndex] ?? [] {
                let sourcePrefix =
                    block.source == DocumentBlockSource.ocr ? "OCR 原文\n" : "原文\n"
                append(
                    sourcePrefix + block.sourceText,
                    to: output,
                    font: .systemFont(ofSize: 11.5),
                    color: .secondaryLabelColor,
                    spacingAfter: 7
                )
                append(
                    translations[block.id] ?? "等待翻译…",
                    to: output,
                    font: .systemFont(ofSize: 15),
                    color: translations[block.id] == nil ? .tertiaryLabelColor : .labelColor,
                    spacingAfter: 22
                )
            }

            append(
                "",
                to: output,
                font: .systemFont(ofSize: 4),
                color: .separatorColor,
                spacingAfter: 18
            )
            ranges[pageIndex] = NSRange(location: pageStart, length: max(1, output.length - pageStart))
        }

        translationTextView.textStorage?.setAttributedString(output)
        pageRanges = ranges
        updateTranslatedPageView()
        exportButton.isEnabled =
            completedPageCount() > 0
            && completedPageCount() == pdfView.document?.pageCount

        if viewModeControl.selectedSegment == 1,
            let pageIndex = pendingScrollPage,
            let range = pageRanges[pageIndex]
        {
            pendingScrollPage = nil
            resizeTranslationTextView()
            translationTextView.scrollRangeToVisible(
                NSRange(location: range.location, length: min(1, range.length))
            )
        }
    }

    private func updateTranslatedPageView() {
        guard let document = pdfView.document,
            let page = document.page(at: currentPageIndex)
        else { return }
        let availableWidth = max(360, translationScroll.contentSize.width)
        translatedPageView.update(
            page: page,
            blocks: pageBlocks[currentPageIndex] ?? [],
            translations: translations,
            availableWidth: availableWidth
        )
    }

    private func resizeTranslationTextView() {
        let width = max(320, translationScroll.contentSize.width)
        translationTextView.frame.size.width = width
        translationTextView.textContainer?.containerSize = NSSize(
            width: max(1, width - translationTextView.textContainerInset.width * 2),
            height: .greatestFiniteMagnitude
        )
        if let layoutManager = translationTextView.layoutManager,
            let textContainer = translationTextView.textContainer
        {
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height
            translationTextView.frame.size.height = max(
                translationScroll.contentSize.height,
                usedHeight + translationTextView.textContainerInset.height * 2
            )
        }
    }

    private func append(
        _ text: String,
        to output: NSMutableAttributedString,
        font: NSFont,
        color: NSColor,
        spacingAfter: CGFloat
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = spacingAfter
        output.append(
            NSAttributedString(
                string: text + "\n",
                attributes: [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: paragraph,
                ]
            )
        )
    }

    private func pageStatus(_ state: PageState) -> String {
        switch state {
        case .idle:
            "等待翻译"
        case .extracting:
            "正在提取页面文本"
        case .recognizing:
            "未发现可用文本层，正在本机 OCR"
        case .translating(let completed, let total):
            "正在翻译 \(completed) / \(total)"
        case .complete:
            "已完成"
        case .failed(let message):
            "失败：\(message)"
        }
    }

    private func statusColor(_ state: PageState) -> NSColor {
        switch state {
        case .complete:
            .systemGreen
        case .failed:
            .systemRed
        case .recognizing:
            .systemOrange
        default:
            .secondaryLabelColor
        }
    }

    private func updateProgressStatus() {
        guard let document = pdfView.document else { return }
        statusLabel.stringValue =
            "已完成 \(completedPageCount()) / \(document.pageCount) 页"
    }

    private func completedPageCount() -> Int {
        pageStates.values.reduce(into: 0) { count, state in
            if case .complete = state {
                count += 1
            }
        }
    }

    private func finishRunning() {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        stopButton.isEnabled = false
        if documentDigest != nil,
            completedPageCount() != pdfView.document?.pageCount
        {
            translateAllButton.title = "翻译全文"
            translateAllButton.isEnabled = true
        }
    }

}
