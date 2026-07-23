import AppKit
import GlossCore

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    var onRequestAccessibility: (() -> Void)?
    var onVerifyProvider: (() -> Void)?
    var onProviderConfigurationChange: ((TranslationProviderConfiguration) -> Void)?
    var onLoginChatGPT: (() -> Void)?
    var onTranslateClipboard: (() -> Void)?
    var onTranslateClipboardImage: (() -> Void)?
    var onTranslateScreenshot: (() -> Void)?
    var onCopyBrowserToken: (() -> Void)?
    var onRevealBrowserExtension: (() -> Void)?
    var onOpenSafariExtensionSettings: (() -> Void)?
    var onBridgeAction: (() -> Void)?
    var onPDFRuntimeAction: ((PDFRuntimeDashboardAction) -> Void)?
    var onRevealLogs: (() -> Void)?
    var onOpenServicesSettings: (() -> Void)?
    var onSetLaunchAtLogin: ((Bool) -> Bool)?
    var onSetGlobalShortcut: ((GlobalShortcut) -> Void)?

    private let window: NSWindow
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let providerStatus = NSTextField(labelWithString: "正在启动翻译引擎")
    private let bridgeStatus = NSTextField(labelWithString: "正在检查本地连接…")
    private let bridgeDetail = NSTextField(labelWithString: "127.0.0.1:8787")
    private let bridgePath = NSTextField(labelWithString: "")
    private let pdfRuntimeStatus = NSTextField(labelWithString: "正在检查 PDF 运行时…")
    private let pdfRuntimeDetail = NSTextField(
        labelWithString: "正在验证已安装版本与残留进程"
    )
    private let pdfRuntimePath = NSTextField(labelWithString: "")
    private let browserExtensionStatus = NSTextField(labelWithString: "正在准备浏览器扩展")
    private let shortcutStatus = NSTextField(labelWithString: "手动翻译当前选区")
    private let launchAtLoginStatus = NSTextField(labelWithString: "关闭")
    private let verifyButton = NSButton(title: "验证", target: nil, action: nil)
    private let loginButton = NSButton(title: "登录 ChatGPT", target: nil, action: nil)
    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let codexModelField = NSTextField(
        string: TranslationProviderConfiguration.defaultCodexModel
    )
    private let reasoningPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let codexOptions = NSStackView()
    private let localOptions = NSStackView()
    private let accessibilityButton = NSButton(title: "启用辅助功能", target: nil, action: nil)
    private let servicesButton = NSButton(title: "打开设置", target: nil, action: nil)
    private let shortcutButton = ShortcutRecorderButton(shortcut: .defaultValue)
    private let launchAtLoginSwitch = NSSwitch()
    private let bridgeActionButton = NSButton(title: "正在检查…", target: nil, action: nil)
    private let bridgeProgressIndicator = NSProgressIndicator()
    private let pdfRuntimeActionButton = NSButton(
        title: "正在检查…",
        target: nil,
        action: nil
    )
    private let pdfRuntimeProgressIndicator = NSProgressIndicator()
    private var pdfRuntimeState = PDFRuntimeDashboardState.checking

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 840),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        super.init()
        configureWindow()
    }

    func show() {
        updateAccessibilityStatus()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func updateAccessibilityStatus() {
        let trusted = SelectionMonitor.isAccessibilityTrusted
        accessibilityStatus.stringValue =
            trusted
            ? "已启用，可以读取其他 App 的当前选区"
            : "尚未启用，仍可使用剪贴板与截图翻译"
        accessibilityStatus.textColor = trusted ? .systemGreen : .secondaryLabelColor
        accessibilityButton.title = trusted ? "已启用" : "启用辅助功能"
        accessibilityButton.isEnabled = !trusted
    }

    func showProviderConfiguration(_ configuration: TranslationProviderConfiguration) {
        select(configuration.provider, in: providerPopup)
        codexModelField.stringValue = configuration.codexModel
        select(configuration.codexReasoningEffort, in: reasoningPopup)
        updateProviderControls()
    }

    func setProviderVerifying() {
        verifyButton.isEnabled = false
        loginButton.isEnabled = false
        verifyButton.title = "正在验证…"
        providerStatus.stringValue =
            selectedProvider == .llama
            ? "正在启动本地 llama-server；首次使用会下载模型"
            : "正在启动 Codex app-server"
        providerStatus.textColor = .secondaryLabelColor
    }

    func setCodexLoginInProgress() {
        verifyButton.isEnabled = false
        loginButton.isEnabled = false
        loginButton.title = "等待登录…"
        providerStatus.stringValue = "请在浏览器中完成 ChatGPT 登录"
        providerStatus.textColor = .secondaryLabelColor
    }

    func showProviderResult(_ message: String, succeeded: Bool) {
        verifyButton.isEnabled = true
        loginButton.isEnabled = selectedProvider == .codex
        verifyButton.title = "重新验证"
        loginButton.title = succeeded ? "切换账号" : "登录 ChatGPT"
        providerStatus.stringValue = message
        providerStatus.textColor = succeeded ? .systemGreen : .systemRed
    }

    func showLaunchAtLoginStatus(enabled: Bool, requiresApproval: Bool) {
        launchAtLoginSwitch.state = enabled ? .on : .off
        if enabled {
            launchAtLoginStatus.stringValue = "已启用，登录后自动运行"
            launchAtLoginStatus.textColor = .systemGreen
        } else if requiresApproval {
            launchAtLoginStatus.stringValue = "等待在系统设置中批准"
            launchAtLoginStatus.textColor = .systemOrange
        } else {
            launchAtLoginStatus.stringValue = "关闭；可让选区翻译随时可用"
            launchAtLoginStatus.textColor = .secondaryLabelColor
        }
    }

    func showGlobalShortcut(_ shortcut: GlobalShortcut) {
        shortcutButton.show(shortcut)
    }

    private func configureWindow() {
        window.title = "Gloss"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 520, height: 810)

        let root = NSView()
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)
        window.contentView = root

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = content

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.leadingAnchor.constraint(
                equalTo: scrollView.contentView.leadingAnchor
            ),
            content.trailingAnchor.constraint(
                equalTo: scrollView.contentView.trailingAnchor
            ),
            content.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            content.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        let icon = NSImageView()
        icon.image = GlossBrand.markImage(pointSize: 36)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Gloss")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        let subtitle = NSTextField(labelWithString: "选中，即懂。")
        subtitle.font = .systemFont(ofSize: 15)
        subtitle.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 3
        heading.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [icon, heading])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14
        header.translatesAutoresizingMaskIntoConstraints = false

        let accessibilityCard = makeStatusCard(
            symbol: "selection.pin.in.out",
            title: "系统选区",
            status: accessibilityStatus,
            accessory: accessibilityButton
        )
        accessibilityButton.target = self
        accessibilityButton.action = #selector(requestAccessibility)

        let shortcutCard = makeStatusCard(
            symbol: "command",
            title: "全局快捷键",
            status: shortcutStatus,
            accessory: shortcutButton
        )
        shortcutButton.onChange = { [weak self] shortcut in
            self?.onSetGlobalShortcut?(shortcut)
        }

        let servicesStatus = NSTextField(
            labelWithString: "在“键盘快捷键 › 服务”中启用文本与图片入口"
        )
        let servicesCard = makeStatusCard(
            symbol: "keyboard",
            title: "系统服务",
            status: servicesStatus,
            accessory: servicesButton
        )
        servicesButton.target = self
        servicesButton.action = #selector(openServicesSettings)

        let providerCard = makeProviderCard()

        let browserCard = makeBridgeCard()
        let pdfRuntimeCard = makePDFRuntimeCard()

        let launchAtLoginCard = makeStatusCard(
            symbol: "power",
            title: "登录时启动",
            status: launchAtLoginStatus,
            accessory: launchAtLoginSwitch
        )
        launchAtLoginSwitch.target = self
        launchAtLoginSwitch.action = #selector(setLaunchAtLogin(_:))

        let clipboardButton = NSButton(title: "翻译文本", target: self, action: #selector(translateClipboard))
        clipboardButton.bezelStyle = .rounded
        clipboardButton.controlSize = .large
        clipboardButton.keyEquivalent = "\r"

        let imageButton = NSButton(
            title: "翻译图片",
            target: self,
            action: #selector(translateClipboardImage)
        )
        imageButton.bezelStyle = .rounded
        imageButton.controlSize = .large

        let screenshotButton = NSButton(
            title: "截图翻译…",
            target: self,
            action: #selector(translateScreenshot)
        )
        screenshotButton.bezelStyle = .rounded
        screenshotButton.controlSize = .large

        let actionButtons = NSStackView(views: [clipboardButton, imageButton, screenshotButton])
        actionButtons.orientation = .horizontal
        actionButtons.alignment = .centerY
        actionButtons.spacing = 8
        actionButtons.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(
            wrappingLabelWithString:
                "选择文本或长按已有选区后 GlossBar 会自动出现；也可以使用全局快捷键，翻译剪贴板图片或截图。图片始终在本机完成 OCR；使用本地模型时，文字也不会离开设备。"
        )
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false

        for view in [
            header,
            accessibilityCard,
            shortcutCard,
            servicesCard,
            providerCard,
            browserCard,
            pdfRuntimeCard,
            launchAtLoginCard,
            actionButtons,
            hint,
        ] {
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            header.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -32),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),

            accessibilityCard.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 26),
            accessibilityCard.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            accessibilityCard.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),

            shortcutCard.topAnchor.constraint(equalTo: accessibilityCard.bottomAnchor, constant: 10),
            shortcutCard.leadingAnchor.constraint(equalTo: accessibilityCard.leadingAnchor),
            shortcutCard.trailingAnchor.constraint(equalTo: accessibilityCard.trailingAnchor),

            servicesCard.topAnchor.constraint(equalTo: shortcutCard.bottomAnchor, constant: 10),
            servicesCard.leadingAnchor.constraint(equalTo: accessibilityCard.leadingAnchor),
            servicesCard.trailingAnchor.constraint(equalTo: accessibilityCard.trailingAnchor),

            providerCard.topAnchor.constraint(equalTo: servicesCard.bottomAnchor, constant: 10),
            providerCard.leadingAnchor.constraint(equalTo: servicesCard.leadingAnchor),
            providerCard.trailingAnchor.constraint(equalTo: servicesCard.trailingAnchor),

            browserCard.topAnchor.constraint(equalTo: providerCard.bottomAnchor, constant: 10),
            browserCard.leadingAnchor.constraint(equalTo: providerCard.leadingAnchor),
            browserCard.trailingAnchor.constraint(equalTo: providerCard.trailingAnchor),

            pdfRuntimeCard.topAnchor.constraint(
                equalTo: browserCard.bottomAnchor,
                constant: 10
            ),
            pdfRuntimeCard.leadingAnchor.constraint(equalTo: browserCard.leadingAnchor),
            pdfRuntimeCard.trailingAnchor.constraint(equalTo: browserCard.trailingAnchor),

            launchAtLoginCard.topAnchor.constraint(
                equalTo: pdfRuntimeCard.bottomAnchor,
                constant: 10
            ),
            launchAtLoginCard.leadingAnchor.constraint(equalTo: browserCard.leadingAnchor),
            launchAtLoginCard.trailingAnchor.constraint(equalTo: browserCard.trailingAnchor),

            actionButtons.topAnchor.constraint(equalTo: launchAtLoginCard.bottomAnchor, constant: 24),
            actionButtons.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            hint.topAnchor.constraint(equalTo: actionButtons.bottomAnchor, constant: 16),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 44),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -44),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    private func makePDFRuntimeCard() -> NSView {
        let card = NSVisualEffectView()
        card.material = .contentBackground
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "doc.richtext",
            accessibilityDescription: "PDF 运行时"
        )
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "PDF 运行时")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        pdfRuntimeProgressIndicator.style = .spinning
        pdfRuntimeProgressIndicator.controlSize = .small

        pdfRuntimeStatus.font = .systemFont(ofSize: 12, weight: .medium)
        pdfRuntimeStatus.lineBreakMode = .byTruncatingTail
        pdfRuntimeStatus.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        let statusStack = NSStackView(
            views: [pdfRuntimeProgressIndicator, pdfRuntimeStatus]
        )
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 5

        pdfRuntimeActionButton.target = self
        pdfRuntimeActionButton.action = #selector(performPDFRuntimeAction)
        pdfRuntimeActionButton.setContentHuggingPriority(
            .required,
            for: .horizontal
        )

        let topRow = NSStackView(
            views: [titleLabel, statusStack, pdfRuntimeActionButton]
        )
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 10
        topRow.distribution = .fill

        pdfRuntimeDetail.font = .systemFont(ofSize: 11.5)
        pdfRuntimeDetail.textColor = .secondaryLabelColor
        pdfRuntimeDetail.lineBreakMode = .byTruncatingMiddle
        pdfRuntimeDetail.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        pdfRuntimePath.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        pdfRuntimePath.textColor = .tertiaryLabelColor
        pdfRuntimePath.lineBreakMode = .byTruncatingMiddle
        pdfRuntimePath.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        pdfRuntimePath.isHidden = true

        let content = NSStackView(
            views: [topRow, pdfRuntimeDetail, pdfRuntimePath]
        )
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        content.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(icon)
        card.addSubview(content)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 92),
            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            content.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            topRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            pdfRuntimeDetail.widthAnchor.constraint(equalTo: content.widthAnchor),
            pdfRuntimePath.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        showPDFRuntimeState(pdfRuntimeState)
        return card
    }

    private func makeBridgeCard() -> NSView {
        let card = NSVisualEffectView()
        card.material = .contentBackground
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "point.3.connected.trianglepath.dotted",
            accessibilityDescription: "本地翻译桥接"
        )
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "本地翻译桥接")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        bridgeProgressIndicator.style = .spinning
        bridgeProgressIndicator.controlSize = .small
        bridgeProgressIndicator.isHidden = false

        bridgeStatus.font = .systemFont(ofSize: 12, weight: .medium)
        bridgeStatus.lineBreakMode = .byTruncatingTail
        bridgeStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let statusStack = NSStackView(views: [bridgeProgressIndicator, bridgeStatus])
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 5

        bridgeActionButton.target = self
        bridgeActionButton.action = #selector(performBridgeAction)
        bridgeActionButton.setContentHuggingPriority(.required, for: .horizontal)

        let topRow = NSStackView(views: [titleLabel, statusStack, bridgeActionButton])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 10
        topRow.distribution = .fill

        bridgeDetail.font = .systemFont(ofSize: 11.5)
        bridgeDetail.textColor = .secondaryLabelColor
        bridgeDetail.lineBreakMode = .byTruncatingMiddle
        bridgeDetail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        bridgePath.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        bridgePath.textColor = .tertiaryLabelColor
        bridgePath.lineBreakMode = .byTruncatingMiddle
        bridgePath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bridgePath.isHidden = true

        browserExtensionStatus.font = .systemFont(ofSize: 11)
        browserExtensionStatus.textColor = .secondaryLabelColor
        browserExtensionStatus.lineBreakMode = .byTruncatingTail
        browserExtensionStatus.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        let revealExtensionButton = NSButton(
            title: "显示扩展",
            target: self,
            action: #selector(revealBrowserExtension)
        )
        let tokenButton = NSButton(
            title: "复制令牌",
            target: self,
            action: #selector(copyBrowserToken)
        )
        let safariButton = NSButton(
            title: "Safari 设置",
            target: self,
            action: #selector(openSafariExtensionSettings)
        )
        for button in [safariButton, revealExtensionButton, tokenButton] {
            button.controlSize = .small
        }
        let browserButtons = NSStackView(
            views: [safariButton, revealExtensionButton, tokenButton]
        )
        browserButtons.orientation = .horizontal
        browserButtons.alignment = .centerY
        browserButtons.spacing = 5

        let extensionRow = NSStackView(views: [browserExtensionStatus, browserButtons])
        extensionRow.orientation = .horizontal
        extensionRow.alignment = .centerY
        extensionRow.spacing = 8
        extensionRow.distribution = .fill

        let content = NSStackView(
            views: [topRow, bridgeDetail, bridgePath, extensionRow]
        )
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        content.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(icon)
        card.addSubview(content)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 118),
            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            content.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            topRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            bridgeDetail.widthAnchor.constraint(equalTo: content.widthAnchor),
            bridgePath.widthAnchor.constraint(equalTo: content.widthAnchor),
            extensionRow.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        bridgeProgressIndicator.startAnimation(nil)
        return card
    }

    private func makeProviderCard() -> NSView {
        let card = NSVisualEffectView()
        card.material = .contentBackground
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "bolt.horizontal.circle",
            accessibilityDescription: "翻译引擎"
        )
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        providerPopup.removeAllItems()
        for provider in TranslationProvider.allCases {
            providerPopup.addItem(withTitle: provider.displayName)
            providerPopup.lastItem?.representedObject = provider.rawValue
        }
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)

        reasoningPopup.removeAllItems()
        for effort in CodexReasoningEffort.allCases {
            reasoningPopup.addItem(withTitle: effort.displayName)
            reasoningPopup.lastItem?.representedObject = effort.rawValue
        }
        reasoningPopup.target = self
        reasoningPopup.action = #selector(providerOptionChanged)

        codexModelField.placeholderString = TranslationProviderConfiguration.defaultCodexModel
        codexModelField.delegate = self
        codexModelField.lineBreakMode = .byTruncatingMiddle

        codexOptions.orientation = .horizontal
        codexOptions.alignment = .centerY
        codexOptions.spacing = 8
        codexOptions.addArrangedSubview(codexModelField)
        let reasoningLabel = makeFieldLabel("推理")
        codexOptions.addArrangedSubview(reasoningLabel)
        codexOptions.addArrangedSubview(reasoningPopup)

        let localDescription = NSTextField(
            labelWithString: "llama.cpp · Hy-MT2-1.8B · Q4_K_M · Metal"
        )
        localDescription.font = .systemFont(ofSize: 12, weight: .medium)
        localDescription.textColor = .secondaryLabelColor
        localOptions.orientation = .horizontal
        localOptions.alignment = .centerY
        localOptions.addArrangedSubview(localDescription)

        let options = NSStackView(views: [codexOptions, localOptions])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 0

        let fields = NSGridView(views: [
            [makeFieldLabel("Provider"), providerPopup],
            [makeFieldLabel("配置"), options],
        ])
        fields.rowSpacing = 8
        fields.columnSpacing = 10
        fields.column(at: 0).xPlacement = .leading
        fields.column(at: 1).xPlacement = .fill

        providerStatus.font = .systemFont(ofSize: 12)
        providerStatus.textColor = .secondaryLabelColor
        providerStatus.lineBreakMode = .byTruncatingTail
        providerStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let logsButton = NSButton(title: "日志", target: self, action: #selector(revealLogs))
        let buttons = NSStackView(views: [loginButton, verifyButton, logsButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 6
        loginButton.target = self
        loginButton.action = #selector(loginChatGPT)
        verifyButton.target = self
        verifyButton.action = #selector(verifyProvider)

        let statusRow = NSStackView(views: [providerStatus, buttons])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 10
        statusRow.distribution = .fill

        let content = NSStackView(views: [fields, statusRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(icon)
        card.addSubview(content)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 152),
            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 19),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            content.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -13),
            fields.widthAnchor.constraint(equalTo: content.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            providerPopup.widthAnchor.constraint(equalToConstant: 330),
            codexModelField.widthAnchor.constraint(equalToConstant: 180),
            reasoningPopup.widthAnchor.constraint(equalToConstant: 112),
        ])

        updateProviderControls()
        return card
    }

    private func makeFieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeStatusCard(
        symbol: String,
        title: String,
        status: NSTextField,
        accessory: NSView
    ) -> NSView {
        let card = NSVisualEffectView()
        card.material = .contentBackground
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        status.font = .systemFont(ofSize: 12)
        status.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [titleLabel, status])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false

        accessory.translatesAutoresizingMaskIntoConstraints = false

        for view in [icon, labels, accessory] {
            card.addSubview(view)
        }

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 68),
            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            labels.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -12),
            accessory.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            accessory.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        return card
    }

    @objc private func requestAccessibility() {
        onRequestAccessibility?()
    }

    @objc private func providerChanged() {
        updateProviderControls()
        notifyProviderConfigurationChange()
    }

    @objc private func providerOptionChanged() {
        notifyProviderConfigurationChange()
    }

    @objc private func verifyProvider() {
        onVerifyProvider?()
    }

    @objc private func loginChatGPT() {
        onLoginChatGPT?()
    }

    @objc private func revealLogs() {
        onRevealLogs?()
    }

    @objc private func translateClipboard() {
        onTranslateClipboard?()
    }

    @objc private func translateClipboardImage() {
        onTranslateClipboardImage?()
    }

    @objc private func translateScreenshot() {
        onTranslateScreenshot?()
    }

    @objc private func copyBrowserToken() {
        onCopyBrowserToken?()
    }

    @objc private func revealBrowserExtension() {
        onRevealBrowserExtension?()
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

    @objc private func openServicesSettings() {
        onOpenServicesSettings?()
    }

    @objc private func setLaunchAtLogin(_ sender: NSSwitch) {
        let requested = sender.state == .on
        let enabled = onSetLaunchAtLogin?(requested) ?? false
        sender.state = enabled ? .on : .off
    }

    func showBridgeState(_ state: BridgeDashboardState) {
        let presentation = state.presentation
        bridgeStatus.stringValue = presentation.headline
        bridgeDetail.stringValue = presentation.detail
        bridgeDetail.toolTip = presentation.detail
        bridgePath.stringValue = presentation.path ?? ""
        bridgePath.toolTip = presentation.path
        bridgePath.isHidden = presentation.path == nil
        bridgeActionButton.title = presentation.actionTitle
        bridgeActionButton.isEnabled = presentation.actionEnabled
        bridgeActionButton.contentTintColor =
            state.occupant.map { $0.canAutomaticallyTerminate ? nil : .systemRed }
            ?? nil
        bridgeProgressIndicator.isHidden = !presentation.showsProgress
        if presentation.showsProgress {
            bridgeProgressIndicator.startAnimation(nil)
        } else {
            bridgeProgressIndicator.stopAnimation(nil)
        }
        bridgeStatus.textColor =
            switch presentation.tone {
            case .neutral: .secondaryLabelColor
            case .positive: .systemGreen
            case .warning: .systemOrange
            case .negative: .systemRed
            }
    }

    func showPDFRuntimeState(_ state: PDFRuntimeDashboardState) {
        pdfRuntimeState = state
        let presentation = state.presentation
        pdfRuntimeStatus.stringValue = presentation.headline
        pdfRuntimeDetail.stringValue = presentation.detail
        pdfRuntimeDetail.toolTip = presentation.detail
        pdfRuntimePath.stringValue = presentation.path ?? ""
        pdfRuntimePath.toolTip = presentation.path
        pdfRuntimePath.isHidden = presentation.path == nil
        pdfRuntimeActionButton.title = presentation.actionTitle
        pdfRuntimeActionButton.isEnabled = presentation.actionEnabled
        pdfRuntimeActionButton.contentTintColor =
            presentation.actionIsDestructive ? .systemRed : nil
        pdfRuntimeProgressIndicator.isHidden = !presentation.showsProgress
        if presentation.showsProgress {
            pdfRuntimeProgressIndicator.startAnimation(nil)
        } else {
            pdfRuntimeProgressIndicator.stopAnimation(nil)
        }
        pdfRuntimeStatus.textColor =
            switch presentation.tone {
            case .neutral: .secondaryLabelColor
            case .positive: .systemGreen
            case .warning: .systemOrange
            case .negative: .systemRed
            }
    }

    func showBrowserExtensionStatus(_ message: String, succeeded: Bool) {
        browserExtensionStatus.stringValue = message
        browserExtensionStatus.textColor = succeeded ? .secondaryLabelColor : .systemRed
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === codexModelField else { return }
        notifyProviderConfigurationChange()
    }

    private var selectedProvider: TranslationProvider {
        guard let rawValue = providerPopup.selectedItem?.representedObject as? String else {
            return .codex
        }
        return TranslationProvider(rawValue: rawValue) ?? .codex
    }

    private var selectedReasoningEffort: CodexReasoningEffort {
        guard let rawValue = reasoningPopup.selectedItem?.representedObject as? String else {
            return .low
        }
        return CodexReasoningEffort(rawValue: rawValue) ?? .low
    }

    private func updateProviderControls() {
        let usesCodex = selectedProvider == .codex
        codexOptions.isHidden = !usesCodex
        localOptions.isHidden = usesCodex
        loginButton.isHidden = !usesCodex
        loginButton.isEnabled = usesCodex
        verifyButton.title = usesCodex ? "验证 GPT" : "验证本地"
    }

    private func notifyProviderConfigurationChange() {
        let model = codexModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onProviderConfigurationChange?(
            TranslationProviderConfiguration(
                provider: selectedProvider,
                codexModel: model.isEmpty
                    ? TranslationProviderConfiguration.defaultCodexModel
                    : model,
                codexReasoningEffort: selectedReasoningEffort
            )
        )
    }

    private func select<Value: RawRepresentable>(_ value: Value, in popup: NSPopUpButton)
    where Value.RawValue == String {
        guard
            let index = popup.itemArray.firstIndex(where: {
                $0.representedObject as? String == value.rawValue
            })
        else { return }
        popup.selectItem(at: index)
    }
}
