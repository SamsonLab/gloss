import AppKit

private final class ResultPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
final class ResultPanelController: NSObject {
    var onCopy: ((String) -> Void)?
    var onReplace: ((String) -> Void)?
    var onBilingual: ((String) -> Void)?

    private static let width: CGFloat = 480
    private static let minimumHeight: CGFloat = 152
    private static let maximumHeight: CGFloat = 420
    private static let verticalChrome: CGFloat = 98

    private let panel: ResultPanel
    private let contextLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let progressIndicator = NSProgressIndicator()
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)
    private let replaceButton = NSButton(title: "替换原文", target: nil, action: nil)
    private let bilingualButton = NSButton(title: "追加双语", target: nil, action: nil)
    private let closeButton = NSButton()
    private var sourceText: String?
    private var translation: String?
    private var anchor = NSPoint.zero

    override init() {
        panel = ResultPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.width,
                height: Self.minimumHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()
        configurePanel()
    }

    func showLoading(selection: SelectionSnapshot, targetLanguage: String) {
        sourceText = selection.text
        translation = nil
        contextLabel.stringValue = "\(selection.applicationName)  ·  \(targetLanguage)"
        statusLabel.stringValue = "正在翻译…"
        statusLabel.textColor = .secondaryLabelColor
        setAttributedText(sourceContent(selection.text))
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        setActionButtons(enabled: false, canReplace: selection.canReplace)
        show(at: selection.anchor)
    }

    func showActivity(
        sourceName: String,
        status: String,
        detail: String,
        at anchor: NSPoint
    ) {
        sourceText = nil
        translation = nil
        contextLabel.stringValue = sourceName
        statusLabel.stringValue = status
        statusLabel.textColor = .secondaryLabelColor
        setAttributedText(plainContent(detail, color: .tertiaryLabelColor))
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        setActionButtons(enabled: false, canReplace: false)
        show(at: anchor)
    }

    func showTranslation(_ value: String, canReplace: Bool) {
        translation = value
        statusLabel.stringValue = "完成"
        statusLabel.textColor = .secondaryLabelColor
        setAttributedText(translationContent(value, source: sourceText))
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        setActionButtons(enabled: true, canReplace: canReplace)
        resizeAndPosition()
    }

    func showError(_ message: String) {
        translation = nil
        statusLabel.stringValue = "翻译失败"
        statusLabel.textColor = .systemRed
        setAttributedText(errorContent(message, source: sourceText))
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        setActionButtons(enabled: false, canReplace: false)
        resizeAndPosition()
    }

    func showStatus(_ message: String, isError: Bool = false) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .systemGreen
    }

    func contains(_ point: NSPoint) -> Bool {
        panel.isVisible && panel.frame.insetBy(dx: -4, dy: -4).contains(point)
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func show(at anchor: NSPoint) {
        self.anchor = anchor
        resizeAndPosition()
        panel.orderFrontRegardless()
    }

    private func resizeAndPosition() {
        let size = NSSize(
            width: Self.width,
            height: preferredHeight(for: textView.attributedString())
        )
        panel.setContentSize(size)

        let screen = NSScreen.screens.first { NSPointInRect(anchor, $0.frame) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? .zero
        let margin: CGFloat = 10
        let horizontalOffset: CGFloat = 44
        let below = anchor.y - size.height - 14
        let above = anchor.y + 18
        let preferredY = below >= visibleFrame.minY + margin ? below : above
        let origin = NSPoint(
            x: min(
                max(anchor.x - horizontalOffset, visibleFrame.minX + margin),
                visibleFrame.maxX - size.width - margin
            ),
            y: min(
                max(preferredY, visibleFrame.minY + margin),
                visibleFrame.maxY - size.height - margin
            )
        )
        panel.setFrameOrigin(origin)
    }

    private func preferredHeight(for text: NSAttributedString) -> CGFloat {
        let textWidth = Self.width - 56
        let bounds = text.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textHeight = min(max(ceil(bounds.height) + 20, 54), 300)
        return min(max(textHeight + Self.verticalChrome, Self.minimumHeight), Self.maximumHeight)
    }

    private func setAttributedText(_ value: NSAttributedString) {
        textView.textStorage?.setAttributedString(value)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private func plainContent(_ text: String, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        return NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 15),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private func sourceContent(_ source: String) -> NSAttributedString {
        let content = NSMutableAttributedString()
        appendSection(
            title: "原文",
            text: source,
            font: .systemFont(ofSize: 13.5),
            color: .secondaryLabelColor,
            to: content
        )
        return content
    }

    private func translationContent(
        _ translation: String,
        source: String?
    ) -> NSAttributedString {
        let content = NSMutableAttributedString()
        appendSection(
            title: "译文",
            text: translation,
            font: .systemFont(ofSize: 15),
            color: .labelColor,
            to: content
        )
        if let source {
            appendSection(
                title: "原文",
                text: source,
                font: .systemFont(ofSize: 13.5),
                color: .secondaryLabelColor,
                separated: true,
                to: content
            )
        }
        return content
    }

    private func errorContent(_ message: String, source: String?) -> NSAttributedString {
        let content = NSMutableAttributedString()
        appendSection(
            title: "错误",
            text: message,
            font: .systemFont(ofSize: 15),
            color: .labelColor,
            to: content
        )
        if let source {
            appendSection(
                title: "原文",
                text: source,
                font: .systemFont(ofSize: 13.5),
                color: .secondaryLabelColor,
                separated: true,
                to: content
            )
        }
        return content
    }

    private func appendSection(
        title: String,
        text: String,
        font: NSFont,
        color: NSColor,
        separated: Bool = false,
        to content: NSMutableAttributedString
    ) {
        if separated {
            content.append(NSAttributedString(string: "\n\n"))
        }

        let headingParagraph = NSMutableParagraphStyle()
        headingParagraph.paragraphSpacing = 4
        content.append(
            NSAttributedString(
                string: "\(title)\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .paragraphStyle: headingParagraph,
                ]
            )
        )

        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 3
        content.append(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: bodyParagraph,
                ]
            )
        )
    }

    private func configurePanel() {
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.onCancel = { [weak self] in self?.hide() }
        panel.setAccessibilityLabel("Gloss 翻译结果")

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.65).cgColor
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        let icon = NSImageView()
        icon.image = GlossBrand.markImage(pointSize: 18)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        contextLabel.font = .systemFont(ofSize: 12, weight: .medium)
        contextLabel.textColor = .secondaryLabelColor
        contextLabel.lineBreakMode = .byTruncatingTail
        contextLabel.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isHidden = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let statusStack = NSStackView(views: [progressIndicator, statusLabel])
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 6
        statusStack.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "关闭"
        )
        closeButton.imagePosition = .imageOnly
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.toolTip = "关闭 (Esc)"
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 10, height: 9)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.isRichText = true
        textView.setAccessibilityLabel("译文与原文")

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 9
        scrollView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.42).cgColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        copyButton.target = self
        copyButton.action = #selector(copyResult)
        replaceButton.target = self
        replaceButton.action = #selector(replaceResult)
        bilingualButton.target = self
        bilingualButton.action = #selector(appendBilingual)
        for button in [copyButton, replaceButton, bilingualButton] {
            button.controlSize = .small
            button.bezelStyle = .rounded
        }

        let buttonStack = NSStackView(views: [copyButton, replaceButton, bilingualButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 7
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        for view in [
            icon,
            contextLabel,
            statusStack,
            closeButton,
            scrollView,
            buttonStack,
        ] {
            effect.addSubview(view)
        }

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: contextLabel.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            contextLabel.topAnchor.constraint(equalTo: effect.topAnchor, constant: 13),
            contextLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            contextLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusStack.leadingAnchor, constant: -10),

            closeButton.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: contextLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),

            statusStack.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -7),
            statusStack.centerYAnchor.constraint(equalTo: contextLabel.centerYAnchor),
            statusStack.widthAnchor.constraint(lessThanOrEqualToConstant: 174),

            scrollView.topAnchor.constraint(equalTo: contextLabel.bottomAnchor, constant: 11),
            scrollView.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -11),

            buttonStack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
            buttonStack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -12),
        ])
    }

    private func setActionButtons(enabled: Bool, canReplace: Bool) {
        copyButton.isEnabled = enabled
        replaceButton.isEnabled = enabled && canReplace
        bilingualButton.isEnabled = enabled && canReplace
    }

    @objc private func close() {
        hide()
    }

    @objc private func copyResult() {
        guard let translation else { return }
        onCopy?(translation)
    }

    @objc private func replaceResult() {
        guard let translation else { return }
        onReplace?(translation)
    }

    @objc private func appendBilingual() {
        guard let translation else { return }
        onBilingual?(translation)
    }
}
