import AppKit
import GlossCore
import GlossOCR
import SafariServices
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class GlossAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum MenuTag {
        static let automaticSelection = 10_001
        static let currentApplication = 10_002
        static let launchAtLogin = 10_003
    }

    private let languages = TranslationLanguages.common
    private let targetLanguageKey = "targetLanguage"
    private let reverseLanguageKey = "reverseLanguage"
    private let smartReverseKey = "smartReverseEnabled"
    private let historyEnabledKey = "historyEnabled"
    private let automaticSelectionKey = "automaticSelectionEnabled"
    private let excludedApplicationsKey = "excludedApplicationBundleIdentifiers"
    private let profileKey = "translationProfile"
    private let providerKey = "translationProvider"
    private let codexModelKey = "codexModel"
    private let codexReasoningEffortKey = "codexReasoningEffort"
    private let glossaryRevisionKey = "glossaryRevision"
    private let welcomeVersionKey = "welcomeVersion"
    private let glossaryStore = GlossaryStore()
    private let runtimeLog = GlossRuntimeLog.shared
    private let dispatchState = TranslationDispatchState()
    private lazy var codex = makeCodexClient(configuration: providerConfiguration)
    private lazy var llama = LlamaServerClient(glossaryStore: glossaryStore)
    private lazy var backendRouter = TranslationBackendRouter(
        backend: backend(for: providerConfiguration.provider)
    )
    private lazy var dispatchCenter = TranslationDispatchCenter(
        backend: backendRouter,
        dispatchState: dispatchState
    )
    private lazy var broker = TranslationBroker(backend: dispatchCenter)
    private let historyStore = TranslationHistoryStore()
    private var globalShortcut = GlobalShortcut.load()
    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let servicesProvider = GlossServicesProvider()
    private var glossBarController: GlossBarController?
    private var resultPanelController: ResultPanelController?
    private var settingsWindowController: SettingsWindowController?
    private var historyWindowController: HistoryWindowController?
    private var glossaryWindowController: GlossaryWindowController?
    private var appExclusionsWindowController: AppExclusionsWindowController?
    private var pdfTranslationWindowController: PDFTranslationWindowController?
    private var selectionMonitor: SelectionMonitor?
    private var currentSelection: SelectionSnapshot?
    private var activeTranslationID: UUID?
    private var activeOCRTask: Task<Void, Never>?
    private var accessibilityTimer: Timer?
    private var accessibilityPollingDeadline: Date?
    private var lastAccessibilityTrusted: Bool?
    private var pairingToken: String?
    private var loopbackServer: LoopbackServer?
    private var terminationInProgress = false
    private var lastExternalApplication: NSRunningApplication?
    private var browserStatus = (message: "正在启动本地浏览器桥接", succeeded: true)
    private var engineStatus = (message: "正在启动翻译引擎", succeeded: Optional<Bool>.none)
    private var codexAccountAuthenticated = false
    private var codexLoginInProgress = false
    private var providerConfigurationGeneration = UUID()
    private var providerTransitionTask: Task<Void, Never>?
    private lazy var activeProviderConfiguration = providerConfiguration
    private var activeProviderRevision = UUID()

    private var applicationVersion: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "dev" : trimmed
    }

    private var glossBar: GlossBarController {
        if let glossBarController { return glossBarController }
        let controller = GlossBarController()
        controller.onTranslate = { [weak self] in
            self?.translateCurrentSelection()
        }
        glossBarController = controller
        return controller
    }

    private var resultPanel: ResultPanelController {
        if let resultPanelController { return resultPanelController }
        let controller = ResultPanelController()
        controller.onCopy = { [weak self] text in
            SelectionWriter.copy(text)
            self?.resultPanelController?.showStatus("已复制")
        }
        controller.onReplace = { [weak self] text in
            self?.replaceCurrentSelection(with: text)
        }
        controller.onBilingual = { [weak self] text in
            guard let source = self?.currentSelection?.text else { return }
            self?.replaceCurrentSelection(with: "\(source)\n\(text)")
        }
        resultPanelController = controller
        return controller
    }

    private var settingsWindow: SettingsWindowController {
        if let settingsWindowController { return settingsWindowController }
        let controller = SettingsWindowController()
        controller.onRequestAccessibility = { [weak self] in
            self?.requestAccessibility()
        }
        controller.onVerifyProvider = { [weak self] in
            self?.verifyProvider()
        }
        controller.onProviderConfigurationChange = { [weak self] configuration in
            self?.applyProviderConfiguration(configuration)
        }
        controller.onLoginChatGPT = { [weak self] in
            self?.loginChatGPT()
        }
        controller.onTranslateClipboard = { [weak self] in
            self?.translateClipboard()
        }
        controller.onTranslateClipboardImage = { [weak self] in
            self?.translateClipboardImage()
        }
        controller.onTranslateScreenshot = { [weak self] in
            self?.translateScreenshot()
        }
        controller.onCopyBrowserToken = { [weak self] in
            self?.copyBrowserToken()
        }
        controller.onRevealBrowserExtension = { [weak self] in
            self?.revealBrowserExtension()
        }
        controller.onOpenSafariExtensionSettings = { [weak self] in
            self?.openSafariExtensionSettings()
        }
        controller.onRevealLogs = { [weak self] in
            self?.revealLogs()
        }
        controller.onOpenServicesSettings = { [weak self] in
            self?.openServicesSettings()
        }
        controller.onSetLaunchAtLogin = { [weak self] enabled in
            self?.setLaunchAtLogin(enabled) ?? false
        }
        controller.onSetGlobalShortcut = { [weak self] shortcut in
            self?.setGlobalShortcut(shortcut)
        }
        controller.showBrowserStatus(browserStatus.message, succeeded: browserStatus.succeeded)
        controller.showProviderConfiguration(providerConfiguration)
        if let succeeded = engineStatus.succeeded {
            controller.showProviderResult(engineStatus.message, succeeded: succeeded)
        } else {
            controller.setProviderVerifying()
        }
        controller.showGlobalShortcut(globalShortcut)
        updateLaunchAtLoginStatus(in: controller)
        settingsWindowController = controller
        return controller
    }

    private var historyWindow: HistoryWindowController {
        if let historyWindowController { return historyWindowController }
        let controller = HistoryWindowController(store: historyStore)
        controller.onRetranslate = { [weak self] entry in
            self?.translateExternalText(entry.sourceText, sourceName: "历史记录")
        }
        historyWindowController = controller
        return controller
    }

    private var glossaryWindow: GlossaryWindowController {
        if let glossaryWindowController { return glossaryWindowController }
        let controller = GlossaryWindowController(store: glossaryStore)
        controller.onChange = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(
                UserDefaults.standard.integer(forKey: glossaryRevisionKey) + 1,
                forKey: glossaryRevisionKey
            )
            activeProviderRevision = UUID()
            Task { await broker.clearCache() }
            pdfTranslationWindowController?.translationConfigurationDidChange()
        }
        glossaryWindowController = controller
        return controller
    }

    private var pdfTranslationWindow: PDFTranslationWindowController {
        if let pdfTranslationWindowController { return pdfTranslationWindowController }
        let controller = PDFTranslationWindowController(
            targetLanguage: { [weak self] in
                self?.targetLanguage ?? "Chinese (Simplified)"
            },
            bridgeToken: { [weak self] in
                self?.pairingToken
            },
            translationDispatchState: dispatchState
        )
        pdfTranslationWindowController = controller
        return controller
    }

    private var appExclusionsWindow: AppExclusionsWindowController {
        if let appExclusionsWindowController { return appExclusionsWindowController }
        let controller = AppExclusionsWindowController()
        controller.onChange = { [weak self] bundleIdentifiers in
            self?.setExcludedApplications(bundleIdentifiers)
        }
        appExclusionsWindowController = controller
        return controller
    }

    private var targetLanguage: String {
        get {
            UserDefaults.standard.string(forKey: targetLanguageKey) ?? "Chinese (Simplified)"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: targetLanguageKey)
        }
    }

    private var reverseLanguage: String {
        get {
            if let value = UserDefaults.standard.string(forKey: reverseLanguageKey) {
                return value
            }
            return targetLanguage == "English" ? "Chinese (Simplified)" : "English"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: reverseLanguageKey)
        }
    }

    private var smartReverseEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: smartReverseKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: smartReverseKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: smartReverseKey)
        }
    }

    private var historyEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: historyEnabledKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: historyEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: historyEnabledKey)
        }
    }

    private var automaticSelectionEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: automaticSelectionKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: automaticSelectionKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: automaticSelectionKey)
        }
    }

    private var excludedApplicationBundleIdentifiers: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: excludedApplicationsKey) ?? [])
        }
        set {
            UserDefaults.standard.set(newValue.sorted(), forKey: excludedApplicationsKey)
        }
    }

    private var profile: TranslationProfile {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: profileKey),
                let profile = TranslationProfile(rawValue: rawValue)
            else { return .natural }
            return profile
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: profileKey)
        }
    }

    private var providerConfiguration: TranslationProviderConfiguration {
        get {
            let defaults = UserDefaults.standard
            let provider =
                defaults.string(forKey: providerKey)
                .flatMap(TranslationProvider.init(rawValue:)) ?? .codex
            let model =
                defaults.string(forKey: codexModelKey)
                ?? TranslationProviderConfiguration.defaultCodexModel
            let effort =
                defaults.string(forKey: codexReasoningEffortKey)
                .flatMap(CodexReasoningEffort.init(rawValue:)) ?? .low
            return TranslationProviderConfiguration(
                provider: provider,
                codexModel: model,
                codexReasoningEffort: effort
            )
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue.provider.rawValue, forKey: providerKey)
            defaults.set(newValue.codexModel, forKey: codexModelKey)
            defaults.set(newValue.codexReasoningEffort.rawValue, forKey: codexReasoningEffortKey)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? runtimeLog.prepare()
        runtimeLog.write("app", "started version=\(applicationVersion)")
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            self?.configureStatusItem()
        }
        configureServices()
        configureSelectionMonitor()
        configureWorkspaceObservation()
        startBrowserBridge()
        prewarmProvider()

        if !reconcileAccessibility() {
            startAccessibilityPolling()
        }

        let rawArguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        let arguments = Set(rawArguments)
        if let pdfArgumentIndex = rawArguments.firstIndex(of: "--open-pdf"),
            rawArguments.indices.contains(pdfArgumentIndex + 1)
        {
            let url = URL(fileURLWithPath: rawArguments[pdfArgumentIndex + 1])
            let requestedPage =
                rawArguments.firstIndex(of: "--pdf-page")
                .flatMap { index in
                    rawArguments.indices.contains(index + 1)
                        ? Int(rawArguments[index + 1])
                        : nil
                }
                .map { max(0, $0 - 1) } ?? 0
            DispatchQueue.main.async { [weak self] in
                do {
                    try self?.pdfTranslationWindow.open(url, pageIndex: requestedPage)
                } catch {
                    self?.showAlert(title: "无法打开 PDF", message: error.localizedDescription)
                }
            }
        } else if arguments.contains("--show-history") {
            DispatchQueue.main.async { [weak self] in
                self?.historyWindow.show()
            }
        } else if arguments.contains("--show-glossary") {
            DispatchQueue.main.async { [weak self] in
                self?.glossaryWindow.show()
            }
        } else if arguments.contains("--show-exclusions") {
            DispatchQueue.main.async { [weak self] in
                self?.showAppExclusions()
            }
        } else if arguments.contains("--show-result-preview") {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let selection = SelectionSnapshot(
                    text: "Gloss should feel immediate, precise, and native.",
                    surroundingContext: nil,
                    applicationName: "Safari",
                    bundleIdentifier: "com.apple.Safari",
                    processIdentifier: nil,
                    element: nil,
                    isEditable: true,
                    anchor: NSEvent.mouseLocation
                )
                resultPanel.showLoading(
                    selection: selection,
                    targetLanguage: "简体中文"
                )
                resultPanel.showTranslation(
                    "Gloss 应该给人即时、准确且原生的使用感受。",
                    canReplace: true
                )
            }
        } else if arguments.contains("--show-settings") {
            DispatchQueue.main.async { [weak self] in
                self?.settingsWindow.show()
            }
        } else if UserDefaults.standard.string(forKey: welcomeVersionKey) != "0.1" {
            UserDefaults.standard.set("0.1", forKey: welcomeVersionKey)
            DispatchQueue.main.async { [weak self] in
                self?.settingsWindow.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtimeLog.write("app", "stopping")
        activeOCRTask?.cancel()
        pdfTranslationWindowController?.stop()
        stopAccessibilityPolling()
        selectionMonitor?.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        loopbackServer?.stop()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard
            let filename = filenames.first(where: {
                URL(fileURLWithPath: $0).pathExtension.lowercased() == "pdf"
            })
        else {
            sender.reply(toOpenOrPrint: .failure)
            return
        }

        do {
            try pdfTranslationWindow.open(URL(fileURLWithPath: filename))
            sender.reply(toOpenOrPrint: .success)
        } catch {
            sender.reply(toOpenOrPrint: .failure)
            showAlert(title: "无法打开 PDF", message: error.localizedDescription)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true
        Task { [codex, llama] in
            await codex.stop()
            await llama.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = GlossBrand.markImage(pointSize: 18)
            button.image?.accessibilityDescription = "Gloss"
            button.toolTip = "Gloss · 选中，即懂"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            guard let self else { return }
            statusItem.menu = buildMenu()
        }
    }

    private func configureServices() {
        servicesProvider.onTranslate = { [weak self] text, sourceName in
            self?.translateExternalText(text, sourceName: sourceName)
        }
        servicesProvider.onTranslateImage = { [weak self] image, sourceName in
            self?.translateImage(image, sourceName: "\(sourceName) 图片")
        }
        NSApp.servicesProvider = servicesProvider
    }

    private func configureSelectionMonitor() {
        selectionMonitor = SelectionMonitor(
            onSelection: { [weak self] selection in
                self?.present(selection)
            },
            onDismiss: { [weak self] in
                self?.dismissSelectionUI()
            },
            shouldIgnorePoint: { [weak self] point in
                guard let self else { return false }
                return glossBarController?.contains(point) == true || resultPanelController?.contains(point) == true
            },
            shouldCaptureAutomatically: { [weak self] bundleIdentifier in
                self?.shouldCaptureAutomatically(in: bundleIdentifier) ?? false
            },
            globalShortcut: globalShortcut
        )
    }

    private func configureWorkspaceObservation() {
        rememberExternalApplication(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func workspaceApplicationDidActivate(_ notification: Notification) {
        if reconcileAccessibility() {
            stopAccessibilityPolling()
        }
        updateLaunchAtLoginStatus()
        let application =
            notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        rememberExternalApplication(application)
    }

    private func rememberExternalApplication(_ application: NSRunningApplication?) {
        guard let application,
            application.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return }
        lastExternalApplication = application
    }

    private func shouldCaptureAutomatically(in bundleIdentifier: String?) -> Bool {
        guard automaticSelectionEnabled else { return false }
        guard let bundleIdentifier else { return true }
        return !excludedApplicationBundleIdentifiers.contains(bundleIdentifier)
    }

    private func dismissSelectionUI() {
        activeOCRTask?.cancel()
        activeOCRTask = nil
        activeTranslationID = nil
        currentSelection = nil
        glossBarController?.hide()
        resultPanelController?.hide()
    }

    private func present(_ selection: SelectionSnapshot) {
        activeOCRTask?.cancel()
        activeOCRTask = nil
        currentSelection = selection
        activeTranslationID = nil
        glossBar.show(
            at: selection.anchor,
            targetLanguage: resolvedTargetLanguage(for: selection.text)
        )
    }

    private func translateCurrentSelection() {
        guard let selection = currentSelection else { return }
        let translationID = UUID()
        activeTranslationID = translationID
        glossBar.setLoading(true)
        let targetLanguage = resolvedTargetLanguage(for: selection.text)
        resultPanel.showLoading(
            selection: selection,
            targetLanguage: TranslationLanguages.title(forTargetName: targetLanguage)
        )

        let profile = self.profile
        Task { [weak self] in
            guard let self else { return }
            do {
                let translated = try await broker.translateText(
                    selection.text,
                    targetLanguage: targetLanguage,
                    profile: profile,
                    contentKind: selection.contentKind,
                    context: selection.surroundingContext
                )
                guard activeTranslationID == translationID else { return }
                glossBar.hide()
                resultPanel.showTranslation(translated, canReplace: selection.canReplace)
                recordHistory(
                    selection: selection,
                    translatedText: translated,
                    targetLanguage: targetLanguage,
                    profile: profile
                )
            } catch {
                guard activeTranslationID == translationID else { return }
                glossBar.hide()
                resultPanel.showError(error.localizedDescription)
            }
        }
    }

    private func replaceCurrentSelection(with text: String) {
        guard let selection = currentSelection else { return }
        Task { [weak self] in
            switch await SelectionWriter.replace(selection, with: text) {
            case .replaced:
                self?.resultPanel.showStatus("已替换，可在原应用中撤销")
            case .replacedWithoutClipboardRestore:
                self?.resultPanel.showStatus("已替换，但未能恢复原剪贴板", isError: true)
            case .failed:
                self?.resultPanel.showStatus("无法替换，结果已保留", isError: true)
            }
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.attributedTitle = GlossBrand.menuHeaderTitle(version: applicationVersion)
        title.isEnabled = false
        menu.addItem(title)

        let clipboard = NSMenuItem(
            title: "翻译剪贴板文本",
            action: #selector(translateClipboard),
            keyEquivalent: "t"
        )
        clipboard.keyEquivalentModifierMask = [.command, .option]
        clipboard.target = self
        menu.addItem(clipboard)

        let clipboardImage = NSMenuItem(
            title: "翻译剪贴板图片",
            action: #selector(translateClipboardImage),
            keyEquivalent: "i"
        )
        clipboardImage.keyEquivalentModifierMask = [.command, .option]
        clipboardImage.target = self
        menu.addItem(clipboardImage)

        let screenshot = NSMenuItem(
            title: "截图翻译…",
            action: #selector(translateScreenshot),
            keyEquivalent: ""
        )
        screenshot.target = self
        menu.addItem(screenshot)

        let pdf = NSMenuItem(
            title: "打开 PDF 翻译…",
            action: #selector(openPDFTranslation),
            keyEquivalent: "o"
        )
        pdf.keyEquivalentModifierMask = [.command, .option]
        pdf.target = self
        menu.addItem(pdf)

        let selectedText = NSMenuItem(
            title: "翻译当前选区（\(globalShortcut.displayName)）",
            action: #selector(translateCurrentSelectionFromMenu),
            keyEquivalent: ""
        )
        selectedText.target = self
        selectedText.isEnabled = SelectionMonitor.isAccessibilityTrusted
        menu.addItem(selectedText)

        let automaticSelection = NSMenuItem(
            title: "选中文字后自动显示",
            action: #selector(toggleAutomaticSelection(_:)),
            keyEquivalent: ""
        )
        automaticSelection.tag = MenuTag.automaticSelection
        automaticSelection.target = self
        menu.addItem(automaticSelection)

        let currentApplication = NSMenuItem(
            title: "在当前 App 中自动显示",
            action: #selector(toggleCurrentApplication(_:)),
            keyEquivalent: ""
        )
        currentApplication.tag = MenuTag.currentApplication
        currentApplication.target = self
        menu.addItem(currentApplication)
        let exclusionCount = excludedApplicationBundleIdentifiers.count
        let manageApplications = NSMenuItem(
            title: exclusionCount == 0 ? "管理 App 例外…" : "管理 App 例外…（\(exclusionCount)）",
            action: #selector(showAppExclusions),
            keyEquivalent: ""
        )
        manageApplications.target = self
        menu.addItem(manageApplications)
        updateSelectionMenuItems(in: menu)
        menu.addItem(.separator())

        let languageItem = NSMenuItem(title: "目标语言", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        if TranslationLanguages.language(forTargetName: targetLanguage) == nil {
            let current = NSMenuItem(title: targetLanguage, action: nil, keyEquivalent: "")
            current.state = .on
            languageMenu.addItem(current)
            languageMenu.addItem(.separator())
        }
        for option in languages {
            let item = NSMenuItem(
                title: option.title,
                action: #selector(selectLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option.targetName
            item.state = option.targetName == targetLanguage ? .on : .off
            languageMenu.addItem(item)
        }
        let customLanguage = NSMenuItem(
            title: "其他语言…",
            action: #selector(selectCustomLanguage),
            keyEquivalent: ""
        )
        customLanguage.target = self
        languageMenu.addItem(customLanguage)
        languageMenu.addItem(.separator())

        let smartReverse = NSMenuItem(
            title: "同语种时自动反向",
            action: #selector(toggleSmartReverse(_:)),
            keyEquivalent: ""
        )
        smartReverse.target = self
        smartReverse.state = smartReverseEnabled ? .on : .off
        languageMenu.addItem(smartReverse)

        let reverseItem = NSMenuItem(title: "反向译为", action: nil, keyEquivalent: "")
        let reverseMenu = NSMenu()
        if TranslationLanguages.language(forTargetName: reverseLanguage) == nil {
            let current = NSMenuItem(title: reverseLanguage, action: nil, keyEquivalent: "")
            current.state = .on
            reverseMenu.addItem(current)
            reverseMenu.addItem(.separator())
        }
        for option in languages {
            let item = NSMenuItem(
                title: option.title,
                action: #selector(selectReverseLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option.targetName
            item.state = option.targetName == reverseLanguage ? .on : .off
            item.isEnabled = option.targetName != targetLanguage
            reverseMenu.addItem(item)
        }
        let customReverseLanguage = NSMenuItem(
            title: "其他语言…",
            action: #selector(selectCustomReverseLanguage),
            keyEquivalent: ""
        )
        customReverseLanguage.target = self
        reverseMenu.addItem(customReverseLanguage)
        reverseItem.submenu = reverseMenu
        reverseItem.isEnabled = smartReverseEnabled
        languageMenu.addItem(reverseItem)
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        let profileItem = NSMenuItem(title: "翻译风格", action: nil, keyEquivalent: "")
        let profileMenu = NSMenu()
        for option in TranslationProfile.allCases {
            let item = NSMenuItem(
                title: option.displayName,
                action: #selector(selectProfile(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == profile ? .on : .off
            profileMenu.addItem(item)
        }
        profileItem.submenu = profileMenu
        menu.addItem(profileItem)

        let glossary = NSMenuItem(
            title: "术语表…",
            action: #selector(showGlossary),
            keyEquivalent: ""
        )
        glossary.target = self
        menu.addItem(glossary)

        let history = NSMenuItem(
            title: "翻译历史…",
            action: #selector(showHistory),
            keyEquivalent: ""
        )
        history.target = self
        menu.addItem(history)

        let saveHistory = NSMenuItem(
            title: "保存本地翻译历史",
            action: #selector(toggleHistory(_:)),
            keyEquivalent: ""
        )
        saveHistory.target = self
        saveHistory.state = historyEnabled ? .on : .off
        menu.addItem(saveHistory)
        menu.addItem(.separator())

        if SelectionMonitor.isAccessibilityTrusted {
            let access = NSMenuItem(title: "选区访问已启用", action: nil, keyEquivalent: "")
            access.isEnabled = false
            menu.addItem(access)
        } else {
            let access = NSMenuItem(
                title: "启用选区翻译…",
                action: #selector(requestAccessibility),
                keyEquivalent: ""
            )
            access.target = self
            menu.addItem(access)
        }

        let loginItem = NSMenuItem(
            title: "登录时启动",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        loginItem.tag = MenuTag.launchAtLogin
        loginItem.target = self
        updateLaunchAtLoginMenuItem(loginItem)
        menu.addItem(loginItem)

        let backend: NSMenuItem
        if providerConfiguration.provider == .llama {
            backend = NSMenuItem(
                title: "本地 · \(engineStatus.message)",
                action: nil,
                keyEquivalent: ""
            )
            backend.isEnabled = false
        } else if codexLoginInProgress {
            backend = NSMenuItem(title: "等待 ChatGPT 登录…", action: nil, keyEquivalent: "")
            backend.isEnabled = false
        } else if codexAccountAuthenticated {
            backend = NSMenuItem(title: engineStatus.message, action: nil, keyEquivalent: "")
            backend.isEnabled = false
        } else {
            backend = NSMenuItem(
                title: "登录 ChatGPT…",
                action: #selector(loginChatGPT),
                keyEquivalent: ""
            )
            backend.target = self
        }
        menu.addItem(backend)
        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Gloss 设置…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let logs = NSMenuItem(
            title: "查看运行日志…",
            action: #selector(revealLogs),
            keyEquivalent: ""
        )
        logs.target = self
        menu.addItem(logs)

        let about = NSMenuItem(title: "关于 Gloss", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(
            title: "退出 Gloss",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateSelectionMenuItems(in: menu)
        if let item = menu.item(withTag: MenuTag.launchAtLogin) {
            updateLaunchAtLoginMenuItem(item)
        }
        updateLaunchAtLoginStatus()
    }

    private func updateSelectionMenuItems(in menu: NSMenu) {
        menu.item(withTag: MenuTag.automaticSelection)?.state =
            automaticSelectionEnabled ? .on : .off

        guard let item = menu.item(withTag: MenuTag.currentApplication) else { return }
        guard let application = lastExternalApplication,
            let bundleIdentifier = application.bundleIdentifier
        else {
            item.title = "在当前 App 中自动显示"
            item.representedObject = nil
            item.isEnabled = false
            item.state = .off
            return
        }

        let name = application.localizedName ?? "当前 App"
        item.title = "在 \(name) 中自动显示"
        item.representedObject = bundleIdentifier
        item.isEnabled = automaticSelectionEnabled
        item.state = excludedApplicationBundleIdentifiers.contains(bundleIdentifier) ? .off : .on
    }

    @objc private func translateClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            showAlert(title: "剪贴板为空", message: "复制一段文本后再试。")
            return
        }

        translateExternalText(text, sourceName: "剪贴板")
    }

    @objc private func openPDFTranslation() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "打开并翻译"
        panel.message = "Gloss 使用 BabelDOC 保留版式，并通过当前 provider 翻译完整文档。"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try pdfTranslationWindow.open(url)
        } catch {
            showAlert(title: "无法打开 PDF", message: error.localizedDescription)
        }
    }

    @objc private func translateClipboardImage() {
        do {
            translateImage(
                try ClipboardImage.read(from: .general),
                sourceName: "剪贴板图片"
            )
        } catch {
            showAlert(title: "无法翻译剪贴板图片", message: error.localizedDescription)
        }
    }

    @objc private func translateScreenshot() {
        activeOCRTask?.cancel()
        let workID = UUID()
        let anchor = NSEvent.mouseLocation
        activeTranslationID = workID
        currentSelection = nil
        glossBarController?.hide()
        resultPanel.showActivity(
            sourceName: "截图翻译",
            status: "等待截图…",
            detail: "拖动选取要翻译的屏幕区域，按 Esc 取消。",
            at: anchor
        )

        activeOCRTask = Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await ScreenshotCapture.selection()
                try Task.checkCancellation()
                guard activeTranslationID == workID else { return }

                resultPanel.showActivity(
                    sourceName: "截图 OCR",
                    status: "正在识别文字…",
                    detail: "图片仅在本机处理。",
                    at: anchor
                )
                await recognizeAndTranslate(
                    image,
                    sourceName: "截图 OCR",
                    anchor: anchor,
                    workID: workID
                )
            } catch {
                finishOCR(error, workID: workID)
            }
        }
    }

    private func translateImage(
        _ image: CGImage,
        sourceName: String,
        anchor: NSPoint = NSEvent.mouseLocation
    ) {
        activeOCRTask?.cancel()
        let workID = UUID()
        activeTranslationID = workID
        currentSelection = nil
        glossBarController?.hide()
        resultPanel.showActivity(
            sourceName: sourceName,
            status: "正在识别文字…",
            detail: "图片仅在本机处理。",
            at: anchor
        )
        activeOCRTask = Task { [weak self] in
            await self?.recognizeAndTranslate(
                image,
                sourceName: sourceName,
                anchor: anchor,
                workID: workID
            )
        }
    }

    private func recognizeAndTranslate(
        _ image: CGImage,
        sourceName: String,
        anchor: NSPoint,
        workID: UUID
    ) async {
        do {
            let text = try await OCRTextRecognizer.recognize(image)
            try Task.checkCancellation()
            guard activeTranslationID == workID else { return }

            activeOCRTask = nil
            currentSelection = SelectionSnapshot(
                text: text,
                surroundingContext: nil,
                contentKind: .ocr,
                applicationName: sourceName,
                bundleIdentifier: nil,
                processIdentifier: nil,
                element: nil,
                isEditable: false,
                anchor: anchor
            )
            translateCurrentSelection()
        } catch {
            finishOCR(error, workID: workID)
        }
    }

    private func finishOCR(_ error: Error, workID: UUID) {
        guard activeTranslationID == workID else { return }
        activeOCRTask = nil
        activeTranslationID = nil
        if error is CancellationError || (error as? ScreenshotCaptureError) == .cancelled {
            resultPanel.hide()
            return
        }
        resultPanel.showError(error.localizedDescription)
    }

    private func translateExternalText(_ text: String, sourceName: String) {
        activeOCRTask?.cancel()
        activeOCRTask = nil
        let selection = SelectionSnapshot(
            text: text,
            surroundingContext: nil,
            applicationName: sourceName,
            bundleIdentifier: nil,
            processIdentifier: nil,
            element: nil,
            isEditable: false,
            anchor: NSEvent.mouseLocation
        )
        currentSelection = selection
        translateCurrentSelection()
    }

    private func resolvedTargetLanguage(for text: String) -> String {
        TranslationTargetResolver.resolve(
            primaryTarget: targetLanguage,
            reverseTarget: reverseLanguage,
            sourceText: text,
            smartReverseEnabled: smartReverseEnabled
        )
    }

    private func recordHistory(
        selection: SelectionSnapshot,
        translatedText: String,
        targetLanguage: String,
        profile: TranslationProfile
    ) {
        guard historyEnabled else { return }
        let entry = TranslationHistoryEntry(
            sourceText: selection.text,
            translatedText: translatedText,
            sourceName: selection.applicationName,
            targetLanguage: targetLanguage,
            profile: profile,
            contentKind: selection.contentKind
        )
        Task { [weak self] in
            guard let self else { return }
            try? await historyStore.record(entry)
            historyWindowController?.reloadIfVisible()
        }
    }

    @objc private func translateCurrentSelectionFromMenu() {
        selectionMonitor?.captureNow()
    }

    @objc private func toggleAutomaticSelection(_ sender: NSMenuItem) {
        automaticSelectionEnabled.toggle()
        if !automaticSelectionEnabled {
            dismissSelectionUI()
        }
        statusItem.menu = buildMenu()
    }

    @objc private func toggleCurrentApplication(_ sender: NSMenuItem) {
        guard let bundleIdentifier = sender.representedObject as? String else { return }
        var excluded = excludedApplicationBundleIdentifiers
        if excluded.contains(bundleIdentifier) {
            excluded.remove(bundleIdentifier)
        } else {
            excluded.insert(bundleIdentifier)
            dismissSelectionUI()
        }
        setExcludedApplications(excluded)
    }

    private func setExcludedApplications(_ bundleIdentifiers: Set<String>) {
        excludedApplicationBundleIdentifiers = bundleIdentifiers
        if let currentBundleIdentifier = currentSelection?.bundleIdentifier,
            bundleIdentifiers.contains(currentBundleIdentifier)
        {
            dismissSelectionUI()
        }
        statusItem.menu = buildMenu()
    }

    @objc private func showAppExclusions() {
        appExclusionsWindow.show(
            bundleIdentifiers: excludedApplicationBundleIdentifiers
        )
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        targetLanguage = value
        if reverseLanguage == value {
            reverseLanguage = value == "English" ? "Chinese (Simplified)" : "English"
        }
        pdfTranslationWindowController?.translationConfigurationDidChange()
        statusItem.menu = buildMenu()
    }

    @objc private func selectCustomLanguage() {
        guard
            let value = requestCustomLanguage(
                title: "自定义目标语言",
                currentValue: targetLanguage
            )
        else { return }
        targetLanguage = value
        if reverseLanguage == value {
            reverseLanguage = value == "English" ? "Chinese (Simplified)" : "English"
        }
        pdfTranslationWindowController?.translationConfigurationDidChange()
        statusItem.menu = buildMenu()
    }

    @objc private func toggleSmartReverse(_ sender: NSMenuItem) {
        smartReverseEnabled.toggle()
        statusItem.menu = buildMenu()
    }

    @objc private func selectReverseLanguage(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
            value != targetLanguage
        else { return }
        reverseLanguage = value
        statusItem.menu = buildMenu()
    }

    @objc private func selectCustomReverseLanguage() {
        guard
            let value = requestCustomLanguage(
                title: "自定义反向语言",
                currentValue: reverseLanguage
            )
        else { return }
        guard value != targetLanguage else {
            showAlert(title: "请选择不同语言", message: "反向语言不能与主要目标语言相同。")
            return
        }
        reverseLanguage = value
        statusItem.menu = buildMenu()
    }

    private func requestCustomLanguage(title: String, currentValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "输入语言或地区名称，例如 Dutch、Brazilian Portuguese 或 es-MX。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "使用")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(string: currentValue)
        field.placeholderString = "Language"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TranslationLanguages.isValidTargetName(value) else {
            showAlert(
                title: "语言名称无效",
                message: "请使用不超过 100 个字符的语言或地区名称。"
            )
            return nil
        }
        return value
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
            let value = TranslationProfile(rawValue: rawValue)
        else { return }
        profile = value
        pdfTranslationWindowController?.translationConfigurationDidChange()
        statusItem.menu = buildMenu()
    }

    @objc private func requestAccessibility() {
        _ = SelectionMonitor.requestAccessibilityAccess()
        _ = reconcileAccessibility()
        startAccessibilityPolling()
    }

    private func makeCodexClient(
        configuration: TranslationProviderConfiguration
    ) -> CodexAppServerClient {
        CodexAppServerClient(
            glossaryStore: glossaryStore,
            model: configuration.codexModel,
            reasoningEffort: configuration.codexReasoningEffort,
            dispatchState: dispatchState
        )
    }

    private func backend(for provider: TranslationProvider) -> any TranslationBackend {
        switch provider {
        case .codex:
            codex
        case .llama:
            llama
        }
    }

    private func applyProviderConfiguration(
        _ requestedConfiguration: TranslationProviderConfiguration
    ) {
        let configuration = TranslationProviderConfiguration(
            provider: requestedConfiguration.provider,
            codexModel: requestedConfiguration.codexModel.isEmpty
                ? TranslationProviderConfiguration.defaultCodexModel
                : requestedConfiguration.codexModel,
            codexReasoningEffort: requestedConfiguration.codexReasoningEffort
        )
        let previousConfiguration = providerConfiguration
        guard configuration != previousConfiguration else { return }

        let previousCodex = codex
        providerConfiguration = configuration
        let generation = UUID()
        providerConfigurationGeneration = generation
        if configuration.codexModel != previousConfiguration.codexModel
            || configuration.codexReasoningEffort != previousConfiguration.codexReasoningEffort
        {
            codex = makeCodexClient(configuration: configuration)
        }

        engineStatus = (
            configuration.provider == .llama
                ? "正在启动 Hy-MT2；首次使用会下载模型"
                : "正在连接 \(configuration.codexModel)",
            nil
        )
        settingsWindowController?.showProviderConfiguration(configuration)
        settingsWindowController?.setProviderVerifying()
        statusItem.menu = buildMenu()

        let selectedBackend = backend(for: configuration.provider)
        let selectedCodex = codex
        let selectedLlama = llama
        let previousTransition = providerTransitionTask
        let transition = Task { [weak self] in
            guard let self else { return }
            await previousTransition?.value
            guard providerConfigurationGeneration == generation else { return }
            if previousCodex !== selectedCodex {
                await previousCodex.stop()
            }
            switch configuration.provider {
            case .codex:
                await selectedLlama.stop()
            case .llama:
                await selectedCodex.stop()
            }
            guard providerConfigurationGeneration == generation else { return }
            await backendRouter.use(selectedBackend)
            await broker.clearCache()
            activeProviderConfiguration = configuration
            activeProviderRevision = UUID()
            pdfTranslationWindowController?.translationConfigurationDidChange()
            guard providerConfigurationGeneration == generation else { return }
            prewarmProvider(configuration: configuration, generation: generation)
        }
        providerTransitionTask = transition
    }

    @objc private func verifyProvider() {
        let configuration = providerConfiguration
        let generation = providerConfigurationGeneration
        engineStatus = (
            configuration.provider == .llama ? "正在验证本地模型" : "正在验证 GPT 订阅",
            nil
        )
        settingsWindow.setProviderVerifying()
        Task { [weak self] in
            guard let self else { return }
            do {
                switch configuration.provider {
                case .codex:
                    let account = try await codex.accountStatus(refreshToken: true)
                    guard providerConfigurationGeneration == generation else { return }
                    guard account.isAuthenticated else {
                        codexAccountAuthenticated = false
                        updateEngineStatus("尚未登录 ChatGPT", succeeded: false)
                        return
                    }
                    try await codex.prewarm()
                    guard providerConfigurationGeneration == generation else { return }
                    codexAccountAuthenticated = true
                    updateEngineStatus(accountSummary(account), succeeded: true)
                case .llama:
                    let output = try await llama.translate(
                        TranslationBatchRequest(
                            items: [
                                TranslationItem(
                                    id: "provider-check",
                                    text: "Gloss local translation is ready."
                                )
                            ],
                            targetLanguage: "Chinese (Simplified)",
                            profile: .natural,
                            contentKind: .selection
                        )
                    )
                    guard providerConfigurationGeneration == generation else { return }
                    guard output.first?.text.isEmpty == false else {
                        throw TranslationError.invalidResponse("本地模型验证返回了空译文。")
                    }
                    updateEngineStatus("Hy-MT2-1.8B Q4 · 本地翻译已就绪", succeeded: true)
                }
            } catch {
                guard providerConfigurationGeneration == generation else { return }
                if configuration.provider == .codex {
                    codexAccountAuthenticated = false
                }
                updateEngineStatus(error.localizedDescription, succeeded: false)
            }
        }
    }

    private func prewarmProvider() {
        let configuration = providerConfiguration
        let generation = providerConfigurationGeneration
        prewarmProvider(configuration: configuration, generation: generation)
    }

    private func prewarmProvider(
        configuration: TranslationProviderConfiguration,
        generation: UUID
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                switch configuration.provider {
                case .codex:
                    let account = try await codex.accountStatus()
                    guard providerConfigurationGeneration == generation else { return }
                    guard account.isAuthenticated else {
                        codexAccountAuthenticated = false
                        updateEngineStatus("尚未登录 ChatGPT · 点击登录", succeeded: false)
                        settingsWindow.show()
                        return
                    }
                    try await codex.prewarm()
                    guard providerConfigurationGeneration == generation else { return }
                    codexAccountAuthenticated = true
                    updateEngineStatus(accountSummary(account), succeeded: true)
                case .llama:
                    try await llama.prewarm()
                    guard providerConfigurationGeneration == generation else { return }
                    updateEngineStatus("Hy-MT2-1.8B Q4 · 本地引擎已就绪", succeeded: true)
                }
            } catch {
                guard providerConfigurationGeneration == generation else { return }
                updateEngineStatus(error.localizedDescription, succeeded: false)
            }
        }
    }

    @objc private func loginChatGPT() {
        guard !codexLoginInProgress else { return }
        codexLoginInProgress = true
        settingsWindow.setCodexLoginInProgress()
        engineStatus = ("等待 ChatGPT 登录", nil)
        statusItem.menu = buildMenu()
        Task { [weak self] in
            guard let self else { return }
            do {
                let login = try await codex.startChatGPTLogin()
                runtimeLog.write("codex", "login_start id=\(login.id)")
                guard NSWorkspace.shared.open(login.authorizationURL) else {
                    throw TranslationError.backendUnavailable("无法打开 ChatGPT 登录页面。")
                }
                let account = try await codex.waitForAuthentication()
                try await codex.prewarm()
                codexLoginInProgress = false
                codexAccountAuthenticated = true
                runtimeLog.write("codex", "login_complete mode=\(account.authMode ?? "unknown")")
                updateEngineStatus(accountSummary(account), succeeded: true)
            } catch {
                codexLoginInProgress = false
                codexAccountAuthenticated = false
                runtimeLog.write(
                    "codex",
                    "login_failed error_type=\(String(reflecting: type(of: error)))"
                )
                updateEngineStatus(error.localizedDescription, succeeded: false)
            }
        }
    }

    private func accountSummary(_ account: CodexAccountStatus) -> String {
        let plan = account.planType?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = account.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let plan, !plan.isEmpty, let email, !email.isEmpty {
            return "ChatGPT \(plan.capitalized) · \(email) · 已就绪"
        }
        if let plan, !plan.isEmpty {
            return "ChatGPT \(plan.capitalized) · 翻译引擎已就绪"
        }
        if let email, !email.isEmpty {
            return "\(email) · 翻译引擎已就绪"
        }
        return "ChatGPT 已登录 · 翻译引擎已就绪"
    }

    private func updateEngineStatus(_ message: String, succeeded: Bool) {
        engineStatus = (message, succeeded)
        settingsWindowController?.showProviderResult(message, succeeded: succeeded)
        statusItem.menu = buildMenu()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        _ = setLaunchAtLogin(SMAppService.mainApp.status != .enabled)
    }

    private func setGlobalShortcut(_ shortcut: GlobalShortcut) {
        globalShortcut = shortcut
        shortcut.save()
        selectionMonitor?.updateGlobalShortcut(shortcut)
        settingsWindowController?.showGlobalShortcut(shortcut)
        statusItem.menu = buildMenu()
    }

    private func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        do {
            let status = SMAppService.mainApp.status
            if enabled {
                if status != .requiresApproval, status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            showAlert(title: "无法更改登录项", message: error.localizedDescription)
        }

        let status = SMAppService.mainApp.status
        updateLaunchAtLoginStatus()
        statusItem.menu = buildMenu()
        if enabled, status == .requiresApproval {
            showAlert(
                title: "需要批准登录项",
                message: "请在“系统设置 › 通用 › 登录项与扩展”中允许 Gloss。"
            )
            openLoginItemsSettings()
        }
        return status == .enabled
    }

    private func updateLaunchAtLoginStatus(in controller: SettingsWindowController? = nil) {
        let status = SMAppService.mainApp.status
        (controller ?? settingsWindowController)?.showLaunchAtLoginStatus(
            enabled: status == .enabled,
            requiresApproval: status == .requiresApproval
        )
    }

    private func updateLaunchAtLoginMenuItem(_ item: NSMenuItem) {
        let status = SMAppService.mainApp.status
        item.state = status == .enabled ? .on : .off
        item.title =
            status == .requiresApproval
            ? "登录时启动（等待批准）"
            : "登录时启动"
    }

    private func openLoginItemsSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
            )
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func showAbout() {
        showAlert(
            title: "Gloss",
            message: "选中，即懂。\n\n系统级、上下文感知的 macOS 翻译工具。"
        )
    }

    @objc private func showSettings() {
        updateLaunchAtLoginStatus()
        settingsWindow.show()
    }

    @objc private func revealLogs() {
        do {
            try runtimeLog.prepare()
            runtimeLog.write("app", "logs_revealed")
            NSWorkspace.shared.activateFileViewerSelecting([GlossRuntimeLog.fileURL])
        } catch {
            showAlert(title: "无法打开运行日志", message: error.localizedDescription)
        }
    }

    private func openServicesSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
            ),
            NSWorkspace.shared.open(url)
        else {
            showAlert(
                title: "无法打开系统服务设置",
                message: "请前往“系统设置 › 键盘 › 键盘快捷键 › 服务”。"
            )
            return
        }
    }

    @objc private func showHistory() {
        historyWindow.show()
    }

    @objc private func showGlossary() {
        glossaryWindow.show()
    }

    @objc private func toggleHistory(_ sender: NSMenuItem) {
        historyEnabled.toggle()
        statusItem.menu = buildMenu()
    }

    private func startBrowserBridge() {
        do {
            let token = try PairingTokenStore.loadOrCreate()
            pairingToken = token
            let extensionPreparationError: String?
            do {
                _ = try BrowserExtensionFiles.installBundledCopy(pairingToken: token)
                extensionPreparationError = nil
            } catch {
                extensionPreparationError = error.localizedDescription
            }
            let server = LoopbackServer(
                broker: broker,
                token: token,
                version: applicationVersion,
                dispatchState: dispatchState,
                providerStatus: { [weak self] in
                    guard let self else {
                        return TranslationProviderStatus(
                            provider: .codex,
                            model: TranslationProviderConfiguration.defaultCodexModel,
                            reasoningEffort: .low,
                            configurationRevision: "unavailable",
                            isWarm: false
                        )
                    }
                    return await self.browserProviderStatus()
                }
            )
            server.onStateChange = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .starting:
                        self.updateBrowserStatus("正在启动 127.0.0.1:8787", succeeded: true)
                    case .ready:
                        if let extensionPreparationError {
                            self.updateBrowserStatus(
                                "桥接已就绪；扩展准备失败：\(extensionPreparationError)",
                                succeeded: false
                            )
                        } else {
                            self.updateBrowserStatus(
                                "已就绪 · 扩展已自动配对",
                                succeeded: true
                            )
                        }
                    case .failed(let message):
                        self.updateBrowserStatus(message, succeeded: false)
                    case .stopped:
                        self.updateBrowserStatus("浏览器桥接已停止", succeeded: false)
                    }
                }
            }
            try server.start()
            loopbackServer = server
        } catch {
            updateBrowserStatus(error.localizedDescription, succeeded: false)
        }
    }

    private func browserProviderStatus() async -> TranslationProviderStatus {
        let configuration = activeProviderConfiguration
        let isWarm: Bool
        switch configuration.provider {
        case .codex:
            isWarm = true
        case .llama:
            isWarm = await llama.status().isRunning
        }
        return TranslationProviderStatus(
            provider: configuration.provider,
            model: configuration.provider == .codex
                ? configuration.codexModel
                : TranslationProviderConfiguration.defaultLlamaModel,
            reasoningEffort: configuration.provider == .codex
                ? configuration.codexReasoningEffort
                : nil,
            configurationRevision: activeProviderRevision.uuidString.lowercased(),
            isWarm: isWarm
        )
    }

    private func updateBrowserStatus(_ message: String, succeeded: Bool) {
        browserStatus = (message, succeeded)
        runtimeLog.write("bridge", "status ok=\(succeeded) message=\(message)")
        settingsWindowController?.showBrowserStatus(message, succeeded: succeeded)
    }

    private func copyBrowserToken() {
        guard let pairingToken else {
            settingsWindow.showBrowserStatus("配对令牌不可用", succeeded: false)
            return
        }
        guard let changeCount = SelectionWriter.copySensitive(pairingToken) else {
            settingsWindow.showBrowserStatus("无法复制配对令牌", succeeded: false)
            return
        }
        settingsWindow.showBrowserStatus("配对令牌已复制 · 60 秒后清除", succeeded: true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == changeCount,
                pasteboard.string(forType: .string) == pairingToken
            else { return }
            pasteboard.clearContents()
            self?.settingsWindowController?.showBrowserStatus("配对令牌已从剪贴板清除", succeeded: true)
        }
    }

    private func revealBrowserExtension() {
        guard let pairingToken else {
            showAlert(title: "无法准备浏览器扩展", message: "浏览器配对令牌不可用。")
            return
        }
        do {
            let directory = try BrowserExtensionFiles.installBundledCopy(
                pairingToken: pairingToken
            )
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } catch {
            showAlert(title: "无法准备浏览器扩展", message: error.localizedDescription)
        }
    }

    private func openSafariExtensionSettings() {
        SFSafariApplication.showPreferencesForExtension(
            withIdentifier: "com.samsoncj.gloss.Extension"
        ) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.showAlert(title: "无法打开 Safari 扩展设置", message: error.localizedDescription)
            }
        }
    }

    private func startAccessibilityPolling() {
        accessibilityPollingDeadline = Date().addingTimeInterval(120)
        guard accessibilityTimer == nil else { return }
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(
            timeInterval: 1,
            target: self,
            selector: #selector(checkAccessibility),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func checkAccessibility() {
        if reconcileAccessibility() {
            stopAccessibilityPolling()
            return
        }
        if let deadline = accessibilityPollingDeadline, Date() >= deadline {
            stopAccessibilityPolling()
        }
    }

    @discardableResult
    private func reconcileAccessibility() -> Bool {
        let trusted = SelectionMonitor.isAccessibilityTrusted
        let monitorReady: Bool
        if trusted {
            monitorReady = selectionMonitor?.start() == true
        } else {
            selectionMonitor?.stop()
            monitorReady = false
        }

        settingsWindowController?.updateAccessibilityStatus()
        if let previous = lastAccessibilityTrusted, previous != trusted {
            statusItem.menu = buildMenu()
        }
        lastAccessibilityTrusted = trusted
        return trusted && monitorReady
    }

    private func stopAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        accessibilityPollingDeadline = nil
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
