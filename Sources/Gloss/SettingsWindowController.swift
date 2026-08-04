import AppKit
import GlossCore

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private enum Section: Int, CaseIterable {
        case general
        case engine
        case browser
        case pdf
        case shortcuts
        case updates

        var title: String {
            switch self {
            case .general: "通用"
            case .engine: "翻译引擎"
            case .browser: "浏览器"
            case .pdf: "PDF 组件"
            case .shortcuts: "快捷键与服务"
            case .updates: "更新与诊断"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .engine: "bolt.horizontal.circle"
            case .browser: "globe"
            case .pdf: "doc.richtext"
            case .shortcuts: "command"
            case .updates: "arrow.triangle.2.circlepath.circle"
            }
        }

        var subtitle: String {
            switch self {
            case .general: "管理 Gloss 的外观与启动方式。"
            case .engine: "选择网页与 PDF 翻译使用的模型和账号。"
            case .browser: "管理浏览器扩展、配对令牌与本地连接。"
            case .pdf: "按需安装、更新或移除 PDF 翻译组件。"
            case .shortcuts: "配置系统选区、服务与全局快捷键。"
            case .updates: "检查 Gloss 更新并查看运行日志。"
            }
        }
    }

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
    var onAppUpdateAction: (() -> Void)?
    var onRevealLogs: (() -> Void)?
    var onOpenServicesSettings: (() -> Void)?
    var onSetLaunchAtLogin: ((Bool) -> Bool)?
    var onSetGlobalShortcut: ((GlobalShortcut) -> Void)?

    private let capabilityRegistry: GlossCapabilityRegistry
    private let window: NSWindow
    private let appearanceController = GlossAppearanceController.shared
    private let pageContainer = NSView()
    private var sectionButtons: [Section: NSButton] = [:]
    private var sectionPages: [Section: NSView] = [:]
    private var appearanceButtons: [GlossAppearancePreference: NSButton] = [:]
    private var selectedSection = Section.general
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
    private let appUpdateStatus = NSTextField(labelWithString: "自动检查应用更新")
    private let appUpdateDetail = NSTextField(
        labelWithString: "每 24 小时后台检查一次"
    )
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
    private let pdfRuntimeUninstallButton = NSButton(
        title: "卸载…",
        target: nil,
        action: nil
    )
    private var pdfRuntimeState = PDFRuntimeDashboardState.checking
    private let appUpdateActionButton = NSButton(
        title: "检查更新",
        target: nil,
        action: nil
    )
    private let appUpdateProgressIndicator = NSProgressIndicator()
    private var appUpdateState = AppUpdateDashboardState.unavailable(
        currentVersion: "dev",
        reason: "开发构建"
    )

    init(capabilityRegistry: GlossCapabilityRegistry = .current) {
        self.capabilityRegistry = capabilityRegistry
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        super.init()
        configureWindow()
    }

    func show() {
        if capabilityRegistry.isEnabled(.selectionTranslation) {
            updateAccessibilityStatus()
        }
        if !window.isVisible, !window.setFrameUsingName("GlossSettingsWindow") {
            window.center()
        }
        selectSection(selectedSection)
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
            launchAtLoginStatus.stringValue =
                capabilityRegistry.isEnabled(.selectionTranslation)
                ? "关闭；可让选区翻译随时可用"
                : "关闭；Gloss 仅在手动启动后可用"
            launchAtLoginStatus.textColor = .secondaryLabelColor
        }
    }

    func showGlobalShortcut(_ shortcut: GlobalShortcut) {
        shortcutButton.show(shortcut)
    }

    private func configureWindow() {
        window.title = "Gloss 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 780, height: 560)
        window.setFrameAutosaveName("GlossSettingsWindow")
        window.titlebarAppearsTransparent = true

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let brandIcon = NSImageView()
        brandIcon.image = GlossBrand.markImage(pointSize: 24)
        brandIcon.contentTintColor = .controlAccentColor
        brandIcon.translatesAutoresizingMaskIntoConstraints = false
        let brandTitle = NSTextField(labelWithString: "Gloss")
        brandTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        let brand = NSStackView(views: [brandIcon, brandTitle])
        brand.orientation = .horizontal
        brand.alignment = .centerY
        brand.spacing = 10
        brand.translatesAutoresizingMaskIntoConstraints = false

        var navigationViews: [NSView] = []
        for section in Section.allCases {
            if section == .pdf, !capabilityRegistry.isEnabled(.pdfTranslation) {
                continue
            }
            if section == .updates, !capabilityRegistry.supports(.appUpdates) {
                continue
            }
            let button = NSButton(
                title: section.title,
                image: NSImage(
                    systemSymbolName: section.symbol,
                    accessibilityDescription: section.title
                ) ?? NSImage(),
                target: self,
                action: #selector(selectSectionButton(_:))
            )
            button.tag = section.rawValue
            button.alternateTitle = section.title
            button.alternateImage = button.image
            button.imagePosition = .imageLeading
            button.alignment = .left
            button.bezelStyle = .rounded
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.setButtonType(.toggle)
            button.controlSize = .large
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 38).isActive = true
            sectionButtons[section] = button
            navigationViews.append(button)
        }
        let navigation = NSStackView(views: navigationViews)
        navigation.orientation = .vertical
        navigation.alignment = .leading
        navigation.spacing = 5
        navigation.translatesAutoresizingMaskIntoConstraints = false
        for view in navigationViews {
            view.widthAnchor.constraint(equalTo: navigation.widthAnchor).isActive = true
        }

        let version =
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "dev"
        let versionLabel = NSTextField(labelWithString: "Gloss \(version)")
        versionLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false

        sidebar.addSubview(brand)
        sidebar.addSubview(navigation)
        sidebar.addSubview(versionLabel)
        NSLayoutConstraint.activate([
            brand.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 28),
            brand.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 22),
            brandIcon.widthAnchor.constraint(equalToConstant: 30),
            brandIcon.heightAnchor.constraint(equalToConstant: 30),
            navigation.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 28),
            navigation.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            navigation.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            versionLabel.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 22),
            versionLabel.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -18),
        ])

        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(pageContainer)
        sidebar.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let root = NSView()
        root.addSubview(splitView)
        window.contentView = root
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        var shortcutCards: [NSView] = []
        if capabilityRegistry.isEnabled(.selectionTranslation) {
            let accessibilityCard = makeStatusCard(
                symbol: "selection.pin.in.out",
                title: "系统选区",
                status: accessibilityStatus,
                accessory: accessibilityButton
            )
            accessibilityButton.target = self
            accessibilityButton.action = #selector(requestAccessibility)
            shortcutCards.append(accessibilityCard)

            let shortcutCard = makeStatusCard(
                symbol: "command",
                title: "全局快捷键",
                status: shortcutStatus,
                accessory: shortcutButton
            )
            shortcutButton.onChange = { [weak self] shortcut in
                self?.onSetGlobalShortcut?(shortcut)
            }
            shortcutCards.append(shortcutCard)
        }

        if capabilityRegistry.isEnabled(.clipboardTranslation)
            || capabilityRegistry.isEnabled(.imageTranslation)
        {
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
            shortcutCards.append(servicesCard)
        }

        var generalCards: [NSView] = [makeAppearanceCard()]
        if capabilityRegistry.supports(.launchAtLogin) {
            let launchAtLoginCard = makeStatusCard(
                symbol: "power",
                title: "登录时启动",
                status: launchAtLoginStatus,
                accessory: launchAtLoginSwitch
            )
            launchAtLoginSwitch.target = self
            launchAtLoginSwitch.action = #selector(setLaunchAtLogin(_:))
            generalCards.append(launchAtLoginCard)
        }

        installPage(.general, cards: generalCards)
        installPage(
            .engine,
            cards: capabilityRegistry.supports(.providerConfiguration)
                ? [makeProviderCard()]
                : []
        )
        installPage(
            .browser,
            cards: capabilityRegistry.supports(.translationLoopbackBridge)
                ? [makeBridgeCard()]
                : []
        )
        if capabilityRegistry.isEnabled(.pdfTranslation) {
            installPage(.pdf, cards: [makePDFRuntimeCard()])
        }
        installPage(.shortcuts, cards: shortcutCards)
        if capabilityRegistry.supports(.appUpdates) {
            installPage(.updates, cards: [makeAppUpdateCard(), makeDiagnosticsCard()])
        }
        selectSection(.general)
    }

    private func installPage(_ section: Section, cards: [NSView]) {
        let page = NSView()
        page.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: section.title)
        title.font = .systemFont(ofSize: 26, weight: .bold)
        let subtitle = NSTextField(wrappingLabelWithString: section.subtitle)
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 5
        heading.translatesAutoresizingMaskIntoConstraints = false

        let contentViews: [NSView]
        if cards.isEmpty {
            let empty = NSTextField(
                wrappingLabelWithString: "当前版本没有可配置的项目。"
            )
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = .secondaryLabelColor
            contentViews = [empty]
        } else {
            contentViews = cards
        }
        let stack = NSStackView(views: contentViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        for card in cards {
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        page.addSubview(heading)
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: page.topAnchor, constant: 42),
            heading.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 38),
            heading.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -38),
            stack.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 38),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -38),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: page.bottomAnchor, constant: -30),
        ])

        pageContainer.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
            page.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            page.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
        ])
        page.isHidden = true
        sectionPages[section] = page
    }

    private func makeAppearanceCard() -> NSView {
        let card = NSVisualEffectView()
        card.material = .contentBackground
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "外观")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let preferences: [GlossAppearancePreference] = [.system, .light, .dark]
        let buttons = preferences.map { preference in
            let button = NSButton(
                title: preference.displayName,
                image: NSImage(
                    systemSymbolName: preference.symbolName,
                    accessibilityDescription: preference.displayName
                ) ?? NSImage(),
                target: self,
                action: #selector(selectAppearance(_:))
            )
            button.tag = preferences.firstIndex(of: preference) ?? 0
            button.imagePosition = .imageAbove
            button.imageScaling = .scaleProportionallyDown
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 9
            button.setButtonType(.toggle)
            button.font = .systemFont(ofSize: 12.5, weight: .semibold)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 110).isActive = true
            appearanceButtons[preference] = button
            return button
        }
        let choices = NSStackView(views: buttons)
        choices.orientation = .horizontal
        choices.alignment = .centerY
        choices.distribution = .fillEqually
        choices.spacing = 12
        choices.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(title)
        card.addSubview(choices)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 176),
            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            choices.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            choices.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            choices.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            choices.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -15),
        ])
        updateAppearanceButtons()
        return card
    }

    private func makeDiagnosticsCard() -> NSView {
        let status = NSTextField(
            labelWithString: "打开诊断目录，查看桥接、翻译引擎与 PDF 组件日志"
        )
        let button = NSButton(title: "查看日志", target: self, action: #selector(revealLogs))
        return makeStatusCard(
            symbol: "doc.text.magnifyingglass",
            title: "运行诊断",
            status: status,
            accessory: button
        )
    }

    @objc private func selectSectionButton(_ sender: NSButton) {
        guard let section = Section(rawValue: sender.tag) else { return }
        selectSection(section)
    }

    private func selectSection(_ section: Section) {
        guard sectionPages[section] != nil else { return }
        selectedSection = section
        for (candidate, page) in sectionPages {
            page.isHidden = candidate != section
        }
        for (candidate, button) in sectionButtons {
            let isSelected = candidate == section
            button.state = isSelected ? .on : .off
            button.isBordered = false
            button.layer?.backgroundColor =
                isSelected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.clear.cgColor
            button.contentTintColor = isSelected ? .white : .labelColor
        }
        if section == .general {
            updateAppearanceButtons()
        }
    }

    @objc private func selectAppearance(_ sender: NSButton) {
        let preferences: [GlossAppearancePreference] = [.system, .light, .dark]
        guard preferences.indices.contains(sender.tag) else { return }
        appearanceController.select(preferences[sender.tag])
        updateAppearanceButtons()
        selectSection(selectedSection)
    }

    private func updateAppearanceButtons() {
        let selected = appearanceController.preference
        for (preference, button) in appearanceButtons {
            let isSelected = preference == selected
            button.state = isSelected ? .on : .off
            button.layer?.borderWidth = isSelected ? 2 : 1
            button.layer?.borderColor =
                isSelected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.separatorColor.cgColor
            button.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
            button.contentTintColor = isSelected ? .controlAccentColor : .labelColor
            button.toolTip =
                isSelected
                ? "当前外观：\(preference.displayName)"
                : "切换到\(preference.displayName)"
        }
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
        pdfRuntimeUninstallButton.target = self
        pdfRuntimeUninstallButton.action = #selector(uninstallPDFRuntime)
        pdfRuntimeUninstallButton.contentTintColor = .systemRed
        pdfRuntimeUninstallButton.setContentHuggingPriority(
            .required,
            for: .horizontal
        )

        let topRow = NSStackView(
            views: [
                titleLabel,
                statusStack,
                pdfRuntimeActionButton,
                pdfRuntimeUninstallButton,
            ]
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

    private func makeAppUpdateCard() -> NSView {
        let card = NSVisualEffectView()
        card.material = .contentBackground
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath.circle",
            accessibilityDescription: "Gloss 更新"
        )
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Gloss 更新")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        appUpdateProgressIndicator.style = .spinning
        appUpdateProgressIndicator.controlSize = .small
        appUpdateProgressIndicator.isHidden = true

        appUpdateStatus.font = .systemFont(ofSize: 12, weight: .medium)
        appUpdateStatus.lineBreakMode = .byTruncatingTail
        appUpdateStatus.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        let statusStack = NSStackView(
            views: [appUpdateProgressIndicator, appUpdateStatus]
        )
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 5

        appUpdateActionButton.target = self
        appUpdateActionButton.action = #selector(performAppUpdateAction)
        appUpdateActionButton.setContentHuggingPriority(
            .required,
            for: .horizontal
        )

        let topRow = NSStackView(
            views: [titleLabel, statusStack, appUpdateActionButton]
        )
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 10
        topRow.distribution = .fill

        appUpdateDetail.font = .systemFont(ofSize: 11.5)
        appUpdateDetail.textColor = .secondaryLabelColor
        appUpdateDetail.lineBreakMode = .byTruncatingMiddle
        appUpdateDetail.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        let content = NSStackView(views: [topRow, appUpdateDetail])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 5
        content.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(icon)
        card.addSubview(content)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 76),
            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            content.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            topRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            appUpdateDetail.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        showAppUpdateState(appUpdateState)
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
        for button in [revealExtensionButton, tokenButton] {
            button.controlSize = .small
        }
        var browserButtonViews: [NSView] = [
            revealExtensionButton,
            tokenButton,
        ]
        if capabilityRegistry.supports(.safariExtension) {
            let safariButton = NSButton(
                title: "Safari 设置",
                target: self,
                action: #selector(openSafariExtensionSettings)
            )
            safariButton.controlSize = .small
            browserButtonViews.insert(safariButton, at: 0)
        }
        let browserButtons = NSStackView(
            views: browserButtonViews
        )
        browserButtons.orientation = .horizontal
        browserButtons.alignment = .centerY
        browserButtons.spacing = 5

        let extensionRow = NSStackView(views: [browserExtensionStatus, browserButtons])
        extensionRow.orientation = .horizontal
        extensionRow.alignment = .centerY
        extensionRow.spacing = 8
        extensionRow.distribution = .fill
        extensionRow.isHidden = !capabilityRegistry.isEnabled(.browserTranslation)

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
            card.heightAnchor.constraint(
                equalToConstant:
                    capabilityRegistry.isEnabled(.browserTranslation)
                    ? 118
                    : 92
            ),
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

    private var productSubtitle: String {
        let browser = capabilityRegistry.isEnabled(.browserTranslation)
        let pdf = capabilityRegistry.isEnabled(.pdfTranslation)
        switch (browser, pdf) {
        case (true, true):
            return "浏览器与 PDF 翻译"
        case (true, false):
            return capabilityRegistry.supports(.safariExtension)
                ? "Safari 与 Chrome 翻译"
                : "Chrome 翻译"
        case (false, true):
            return "批量 PDF 翻译"
        case (false, false):
            return capabilityRegistry.isEnabled(.selectionTranslation)
                ? "选中，即懂。"
                : "按需组合的翻译工具"
        }
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

    @objc private func uninstallPDFRuntime() {
        onPDFRuntimeAction?(.uninstall)
    }

    @objc private func performAppUpdateAction() {
        onAppUpdateAction?()
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
        pdfRuntimeUninstallButton.isHidden = !state.hasInstalledRuntime
        pdfRuntimeUninstallButton.isEnabled = state.canRequestUninstall
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

    func showAppUpdateState(_ state: AppUpdateDashboardState) {
        appUpdateState = state
        let presentation = state.presentation
        appUpdateStatus.stringValue = presentation.headline
        appUpdateStatus.toolTip = presentation.headline
        appUpdateDetail.stringValue = presentation.detail
        appUpdateDetail.toolTip = presentation.detail
        appUpdateActionButton.title = presentation.actionTitle
        appUpdateActionButton.isEnabled = presentation.actionEnabled
        appUpdateProgressIndicator.isHidden = !presentation.showsProgress
        if presentation.showsProgress {
            appUpdateProgressIndicator.startAnimation(nil)
        } else {
            appUpdateProgressIndicator.stopAnimation(nil)
        }
        appUpdateStatus.textColor =
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
