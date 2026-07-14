import AppKit
import GlossCore

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    var onRequestAccessibility: (() -> Void)?
    var onVerifyCodex: (() -> Void)?
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
    private let codexStatus = NSTextField(labelWithString: "按需启动，复用当前 Codex 登录")
    private let browserStatus = NSTextField(labelWithString: "正在启动本地浏览器桥接")
    private let shortcutStatus = NSTextField(labelWithString: "手动翻译当前选区")
    private let launchAtLoginStatus = NSTextField(labelWithString: "关闭")
    private let verifyButton = NSButton(title: "验证 Codex", target: nil, action: nil)
    private let accessibilityButton = NSButton(title: "启用辅助功能", target: nil, action: nil)
    private let servicesButton = NSButton(title: "打开设置", target: nil, action: nil)
    private let shortcutButton = ShortcutRecorderButton(shortcut: .defaultValue)
    private let launchAtLoginSwitch = NSSwitch()

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 706),
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

    func setCodexVerifying() {
        verifyButton.isEnabled = false
        verifyButton.title = "正在验证…"
        codexStatus.stringValue = "正在启动 Codex app-server"
        codexStatus.textColor = .secondaryLabelColor
    }

    func showCodexResult(_ message: String, succeeded: Bool) {
        verifyButton.isEnabled = true
        verifyButton.title = "重新验证"
        codexStatus.stringValue = message
        codexStatus.textColor = succeeded ? .systemGreen : .systemRed
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
        window.minSize = NSSize(width: 520, height: 680)

        let content = NSView()
        window.contentView = content

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "character.book.closed.fill",
            accessibilityDescription: "Gloss"
        )
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 36, weight: .semibold)
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

        let logsButton = NSButton(title: "查看日志", target: self, action: #selector(revealLogs))
        let codexButtons = NSStackView(views: [verifyButton, logsButton])
        codexButtons.orientation = .horizontal
        codexButtons.alignment = .centerY
        codexButtons.spacing = 6
        let codexCard = makeStatusCard(
            symbol: "bolt.horizontal.circle",
            title: "翻译引擎",
            status: codexStatus,
            accessory: codexButtons
        )
        verifyButton.target = self
        verifyButton.action = #selector(verifyCodex)

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
                "选择文本或长按已有选区后 GlossBar 会自动出现；也可以使用全局快捷键，翻译剪贴板图片或截图。图片在本机完成 OCR，只有文字会发送给 Codex。"
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
            codexCard,
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

            codexCard.topAnchor.constraint(equalTo: servicesCard.bottomAnchor, constant: 10),
            codexCard.leadingAnchor.constraint(equalTo: servicesCard.leadingAnchor),
            codexCard.trailingAnchor.constraint(equalTo: servicesCard.trailingAnchor),

            browserCard.topAnchor.constraint(equalTo: codexCard.bottomAnchor, constant: 10),
            browserCard.leadingAnchor.constraint(equalTo: codexCard.leadingAnchor),
            browserCard.trailingAnchor.constraint(equalTo: codexCard.trailingAnchor),

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

    @objc private func verifyCodex() {
        onVerifyCodex?()
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
}
