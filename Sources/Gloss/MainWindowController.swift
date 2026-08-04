import AppKit
import GlossCore

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    var onOpenSettings: (() -> Void)?
    var onOpenPDFTranslation: (() -> Void)?
    var onRevealBrowserExtension: (() -> Void)?
    var onCopyBrowserToken: (() -> Void)?
    var onOpenSafariExtensionSettings: (() -> Void)?
    var onBridgeAction: (() -> Void)?
    var onPDFRuntimeAction: ((PDFRuntimeDashboardAction) -> Void)?

    private let capabilityRegistry: GlossCapabilityRegistry
    private let window: NSWindow
    private let appearanceController = GlossAppearanceController.shared
    private let themeButton = NSButton()
    private let browserStatus = NSTextField(labelWithString: "正在启动浏览器翻译…")
    private let browserDetail = NSTextField(labelWithString: "正在准备本地翻译连接")
    private let browserActionButton = NSButton(title: "正在检查…", target: nil, action: nil)
    private let pdfStatus = NSTextField(labelWithString: "正在检查 PDF 组件…")
    private let pdfDetail = NSTextField(labelWithString: "PDF 翻译作为附加能力按需安装")
    private let pdfActionButton = NSButton(title: "正在检查…", target: nil, action: nil)
    private let pdfProgress = NSProgressIndicator()
    private var pdfRuntimeState = PDFRuntimeDashboardState.checking
    private var appearanceObserver: NSObjectProtocol?

    init(capabilityRegistry: GlossCapabilityRegistry = .current) {
        self.capabilityRegistry = capabilityRegistry
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        super.init()
        configureWindow()
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: GlossAppearanceController.didChangeNotification,
            object: appearanceController,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateThemeButton()
            }
        }
    }

    func show() {
        if !window.isVisible, !window.setFrameUsingName("GlossMainWindow") {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showBridgeState(_ state: BridgeDashboardState) {
        let presentation = state.presentation
        browserStatus.stringValue = presentation.headline
        browserStatus.textColor = color(for: presentation.tone)
        browserActionButton.title = presentation.actionTitle
        browserActionButton.isEnabled = presentation.actionEnabled
    }

    func showBrowserExtensionStatus(_ message: String, succeeded: Bool) {
        browserDetail.stringValue = message
        browserDetail.textColor = succeeded ? .secondaryLabelColor : .systemRed
    }

    func showPDFRuntimeState(_ state: PDFRuntimeDashboardState) {
        pdfRuntimeState = state
        let presentation = state.presentation
        pdfStatus.stringValue = presentation.headline
        pdfStatus.textColor = color(for: presentation.tone)
        pdfDetail.stringValue = presentation.detail
        pdfDetail.toolTip = presentation.detail
        pdfActionButton.title = presentation.actionTitle
        pdfActionButton.isEnabled = presentation.actionEnabled
        pdfActionButton.contentTintColor = presentation.actionIsDestructive ? .systemRed : nil
        pdfProgress.isHidden = !presentation.showsProgress
        if presentation.showsProgress {
            pdfProgress.startAnimation(nil)
        } else {
            pdfProgress.stopAnimation(nil)
        }
    }

    private func configureWindow() {
        window.title = "Gloss"
        window.subtitle = "浏览器翻译"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 680, height: 500)
        window.setFrameAutosaveName("GlossMainWindow")
        window.titlebarAppearsTransparent = true

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let brandIcon = NSImageView()
        brandIcon.image = GlossBrand.markImage(pointSize: 28)
        brandIcon.contentTintColor = .controlAccentColor
        brandIcon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Gloss")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        let subtitle = NSTextField(
            labelWithString: "浏览器翻译是默认能力，PDF 翻译按需启用。"
        )
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 3

        let headerLeft = NSStackView(views: [brandIcon, heading])
        headerLeft.orientation = .horizontal
        headerLeft.alignment = .centerY
        headerLeft.spacing = 13

        configureIconButton(
            themeButton,
            symbol: appearanceController.preference.symbolName,
            toolTip: "外观：\(appearanceController.preference.displayName)",
            action: #selector(cycleTheme)
        )
        let settingsButton = NSButton()
        configureIconButton(
            settingsButton,
            symbol: "gearshape",
            toolTip: "Gloss 设置（⌘,）",
            action: #selector(openSettings)
        )
        let headerActions = NSStackView(views: [themeButton, settingsButton])
        headerActions.orientation = .horizontal
        headerActions.alignment = .centerY
        headerActions.spacing = 8

        let header = NSStackView(views: [headerLeft, NSView(), headerActions])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        header.translatesAutoresizingMaskIntoConstraints = false

        let browserCard = makeBrowserCard()
        let pdfCard = makePDFCard()
        let content = NSStackView(views: [browserCard, pdfCard])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        browserCard.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        pdfCard.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        root.addSubview(header)
        root.addSubview(content)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 34),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -34),
            brandIcon.widthAnchor.constraint(equalToConstant: 42),
            brandIcon.heightAnchor.constraint(equalToConstant: 42),
            themeButton.widthAnchor.constraint(equalToConstant: 32),
            themeButton.heightAnchor.constraint(equalToConstant: 32),
            settingsButton.widthAnchor.constraint(equalToConstant: 32),
            settingsButton.heightAnchor.constraint(equalToConstant: 32),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 26),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 34),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -34),
            content.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -28),
        ])
    }

    private func makeBrowserCard() -> NSView {
        let card = makeCard(material: .contentBackground, cornerRadius: 16)
        let icon = makeSymbolView("globe", description: "浏览器翻译", size: 28)
        icon.contentTintColor = .controlAccentColor
        let title = NSTextField(labelWithString: "浏览器翻译")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let badge = makeBadge("默认能力", color: .controlAccentColor)
        let titleRow = NSStackView(views: [title, badge])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8

        let description = NSTextField(
            wrappingLabelWithString: "在 Chrome 或 Safari 中直接翻译网页。Gloss 启动后会自动维护本地连接，无需额外下载 PDF 组件。"
        )
        description.font = .systemFont(ofSize: 13)
        description.textColor = .secondaryLabelColor
        description.maximumNumberOfLines = 2

        browserStatus.font = .systemFont(ofSize: 12.5, weight: .medium)
        browserDetail.font = .systemFont(ofSize: 11.5)
        browserDetail.textColor = .secondaryLabelColor
        browserDetail.lineBreakMode = .byTruncatingTail

        browserActionButton.target = self
        browserActionButton.action = #selector(performBridgeAction)
        let revealButton = NSButton(
            title: "显示 Chrome 扩展",
            target: self,
            action: #selector(revealBrowserExtension)
        )
        let tokenButton = NSButton(
            title: "复制配对令牌",
            target: self,
            action: #selector(copyBrowserToken)
        )
        var actions: [NSView] = [revealButton, tokenButton]
        if capabilityRegistry.supports(.safariExtension) {
            actions.append(
                NSButton(
                    title: "Safari 设置",
                    target: self,
                    action: #selector(openSafariExtensionSettings)
                )
            )
        }
        actions.append(NSView())
        actions.append(browserActionButton)
        let actionRow = NSStackView(views: actions)
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8
        actionRow.distribution = .fill

        let copy = NSStackView(views: [titleRow, description, browserStatus, browserDetail, actionRow])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 8
        copy.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(icon)
        card.addSubview(copy)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 224),
            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 25),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            copy.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            copy.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            copy.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            copy.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            titleRow.widthAnchor.constraint(equalTo: copy.widthAnchor),
            description.widthAnchor.constraint(equalTo: copy.widthAnchor),
            browserStatus.widthAnchor.constraint(equalTo: copy.widthAnchor),
            browserDetail.widthAnchor.constraint(equalTo: copy.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: copy.widthAnchor),
        ])
        return card
    }

    private func makePDFCard() -> NSView {
        let card = makeCard(material: .sidebar, cornerRadius: 14)
        let icon = makeSymbolView("doc.richtext", description: "PDF 翻译", size: 24)
        let title = NSTextField(labelWithString: "PDF 翻译")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let badge = makeBadge("附加组件", color: .secondaryLabelColor)
        let titleRow = NSStackView(views: [title, badge])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8

        pdfStatus.font = .systemFont(ofSize: 12.5, weight: .medium)
        pdfDetail.font = .systemFont(ofSize: 11.5)
        pdfDetail.textColor = .secondaryLabelColor
        pdfDetail.lineBreakMode = .byTruncatingMiddle

        pdfProgress.style = .spinning
        pdfProgress.controlSize = .small
        pdfProgress.isHidden = true
        let statusRow = NSStackView(views: [pdfProgress, pdfStatus])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 6

        let openButton = NSButton(
            title: "打开 PDF 翻译…",
            target: self,
            action: #selector(openPDFTranslation)
        )
        pdfActionButton.target = self
        pdfActionButton.action = #selector(performPDFRuntimeAction)
        let actions = NSStackView(views: [NSView(), pdfActionButton, openButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.distribution = .fill

        let copy = NSStackView(views: [titleRow, statusRow, pdfDetail, actions])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 6
        copy.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(icon)
        card.addSubview(copy)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 154),
            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            copy.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 15),
            copy.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            copy.topAnchor.constraint(equalTo: card.topAnchor, constant: 19),
            copy.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            titleRow.widthAnchor.constraint(equalTo: copy.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: copy.widthAnchor),
            pdfDetail.widthAnchor.constraint(equalTo: copy.widthAnchor),
            actions.widthAnchor.constraint(equalTo: copy.widthAnchor),
        ])
        showPDFRuntimeState(pdfRuntimeState)
        return card
    }

    private func makeCard(
        material: NSVisualEffectView.Material,
        cornerRadius: CGFloat
    ) -> NSVisualEffectView {
        let card = NSVisualEffectView()
        card.material = material
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = cornerRadius
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }

    private func makeSymbolView(
        _ symbol: String,
        description: String,
        size: CGFloat
    ) -> NSImageView {
        let imageView = NSImageView()
        imageView.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: description
        )
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: size,
            weight: .medium
        )
        imageView.contentTintColor = .secondaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }

    private func makeBadge(_ text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "  \(text)  ")
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = color
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.cornerRadius = 6
        label.layer?.backgroundColor = color.withAlphaComponent(0.10).cgColor
        return label
    }

    private func configureIconButton(
        _ button: NSButton,
        symbol: String,
        toolTip: String,
        action: Selector
    ) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
        button.imagePosition = .imageOnly
        button.bezelStyle = .accessoryBarAction
        button.toolTip = toolTip
        button.target = self
        button.action = action
    }

    private func updateThemeButton() {
        let preference = appearanceController.preference
        themeButton.image = NSImage(
            systemSymbolName: preference.symbolName,
            accessibilityDescription: preference.displayName
        )
        themeButton.toolTip = "外观：\(preference.displayName)"
    }

    private func color(for tone: PDFRuntimeDashboardPresentation.Tone) -> NSColor {
        switch tone {
        case .neutral: .secondaryLabelColor
        case .positive: .systemGreen
        case .warning: .systemOrange
        case .negative: .systemRed
        }
    }

    private func color(for tone: BridgeDashboardPresentation.Tone) -> NSColor {
        switch tone {
        case .neutral: .secondaryLabelColor
        case .positive: .systemGreen
        case .warning: .systemOrange
        case .negative: .systemRed
        }
    }

    @objc private func cycleTheme() {
        appearanceController.cycle()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func openPDFTranslation() {
        onOpenPDFTranslation?()
    }

    @objc private func revealBrowserExtension() {
        onRevealBrowserExtension?()
    }

    @objc private func copyBrowserToken() {
        onCopyBrowserToken?()
    }

    @objc private func openSafariExtensionSettings() {
        onOpenSafariExtensionSettings?()
    }

    @objc private func performBridgeAction() {
        onBridgeAction?()
    }

    @objc private func performPDFRuntimeAction() {
        guard let action = pdfRuntimeState.action else { return }
        onPDFRuntimeAction?(action)
    }
}
