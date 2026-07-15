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
    var onRevealLogs: (() -> Void)?
    var onOpenServicesSettings: (() -> Void)?
    var onSetLaunchAtLogin: ((Bool) -> Bool)?
    var onSetGlobalShortcut: ((GlobalShortcut) -> Void)?

    private let window: NSWindow
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let providerStatus = NSTextField(labelWithString: "正在启动翻译引擎")
    private let browserStatus = NSTextField(labelWithString: "正在启动本地浏览器桥接")
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

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 790),
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
        window.minSize = NSSize(width: 520, height: 760)

        let content = NSView()
        window.contentView = content

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

        let revealExtensionButton = NSButton(
            title: "显示扩展",
            target: self,
            action: #selector(revealBrowserExtension)
        )
        let tokenButton = NSButton(title: "复制令牌", target: self, action: #selector(copyBrowserToken))
        let safariButton = NSButton(
            title: "Safari 设置",
            target: self,
            action: #selector(openSafariExtensionSettings)
        )
        let browserButtons = NSStackView(views: [safariButton, revealExtensionButton, tokenButton])
        browserButtons.orientation = .horizontal
        browserButtons.alignment = .centerY
        browserButtons.spacing = 6
        let browserCard = makeStatusCard(
            symbol: "puzzlepiece.extension",
            title: "浏览器扩展",
            status: browserStatus,
            accessory: browserButtons
        )

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

            launchAtLoginCard.topAnchor.constraint(equalTo: browserCard.bottomAnchor, constant: 10),
            launchAtLoginCard.leadingAnchor.constraint(equalTo: browserCard.leadingAnchor),
            launchAtLoginCard.trailingAnchor.constraint(equalTo: browserCard.trailingAnchor),

            actionButtons.topAnchor.constraint(equalTo: launchAtLoginCard.bottomAnchor, constant: 24),
            actionButtons.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            hint.topAnchor.constraint(equalTo: actionButtons.bottomAnchor, constant: 16),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 44),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -44),
            hint.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])
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

    @objc private func openServicesSettings() {
        onOpenServicesSettings?()
    }

    @objc private func setLaunchAtLogin(_ sender: NSSwitch) {
        let requested = sender.state == .on
        let enabled = onSetLaunchAtLogin?(requested) ?? false
        sender.state = enabled ? .on : .off
    }

    func showBrowserStatus(_ message: String, succeeded: Bool) {
        browserStatus.stringValue = message
        browserStatus.textColor = succeeded ? .systemGreen : .systemRed
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
