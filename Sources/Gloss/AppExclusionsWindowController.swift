import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppExclusionsWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onChange: ((Set<String>) -> Void)?

    private struct Row {
        let bundleIdentifier: String
        let name: String
        let icon: NSImage
    }

    private let window: NSWindow
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "没有 App 例外")
    private let removeButton = NSButton(title: "移除", target: nil, action: nil)
    private var bundleIdentifiers: Set<String> = []
    private var rows: [Row] = []

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        super.init()
        configureWindow()
    }

    func show(bundleIdentifiers: Set<String>) {
        self.bundleIdentifiers = bundleIdentifiers
        reload()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }
        let item = rows[row]
        if identifier.rawValue == "app" {
            let view = NSView()
            let icon = NSImageView(image: item.icon)
            icon.translatesAutoresizingMaskIntoConstraints = false
            let name = NSTextField(labelWithString: item.name)
            name.lineBreakMode = .byTruncatingTail
            name.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(icon)
            view.addSubview(name)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 22),
                icon.heightAnchor.constraint(equalToConstant: 22),
                name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                name.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                name.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
            return view
        }

        let bundleLabel = NSTextField(labelWithString: item.bundleIdentifier)
        bundleLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        bundleLabel.textColor = .secondaryLabelColor
        bundleLabel.lineBreakMode = .byTruncatingMiddle
        return bundleLabel
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }

    private func configureWindow() {
        window.title = "App 例外"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 500, height: 320)

        let content = NSView()
        window.contentView = content

        let title = NSTextField(labelWithString: "不自动显示 GlossBar")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = NSTextField(
            wrappingLabelWithString: "Gloss 不会在这些 App 中自动出现；全局快捷键仍然可用。"
        )
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let appColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        appColumn.title = "App"
        appColumn.minWidth = 180
        appColumn.width = 230
        appColumn.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)
        let identifierColumn = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("bundleIdentifier")
        )
        identifierColumn.title = "Bundle Identifier"
        identifierColumn.minWidth = 220
        identifierColumn.width = 300
        identifierColumn.sortDescriptorPrototype = NSSortDescriptor(
            key: "bundleIdentifier",
            ascending: true
        )
        tableView.addTableColumn(appColumn)
        tableView.addTableColumn(identifierColumn)
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 32
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(title: "添加 App…", target: self, action: #selector(addApplications))
        removeButton.target = self
        removeButton.action = #selector(removeApplications)
        removeButton.isEnabled = false
        let buttons = NSStackView(views: [addButton, removeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        for view in [title, subtitle, scrollView, emptyLabel, buttons] {
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            scrollView.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 18),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            buttons.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    private func reload() {
        rows = bundleIdentifiers.map(Self.resolve)
        sortRows()
        tableView.reloadData()
        tableView.deselectAll(nil)
        emptyLabel.isHidden = !rows.isEmpty
        removeButton.isEnabled = false
    }

    func tableView(
        _ tableView: NSTableView,
        sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        sortRows()
        tableView.reloadData()
        tableView.deselectAll(nil)
        removeButton.isEnabled = false
    }

    private func sortRows() {
        let descriptor = tableView.sortDescriptors.first
        let key = descriptor?.key ?? "name"
        let ascending = descriptor?.ascending ?? true
        rows.sort { lhs, rhs in
            let lhsValue = key == "bundleIdentifier" ? lhs.bundleIdentifier : lhs.name
            let rhsValue = key == "bundleIdentifier" ? rhs.bundleIdentifier : rhs.name
            let order = lhsValue.localizedCaseInsensitiveCompare(rhsValue)
            if order == .orderedSame {
                return lhs.bundleIdentifier < rhs.bundleIdentifier
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func resolve(_ bundleIdentifier: String) -> Row {
        let workspace = NSWorkspace.shared
        let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)
        let bundle = url.flatMap(Bundle.init(url:))
        let name =
            (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url?.deletingPathExtension().lastPathComponent
            ?? bundleIdentifier
        let icon =
            url.map { workspace.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: name)
            ?? NSImage(size: NSSize(width: 32, height: 32))
        return Row(bundleIdentifier: bundleIdentifier, name: name, icon: icon)
    }

    @objc private func addApplications() {
        let panel = NSOpenPanel()
        panel.title = "添加 App 例外"
        panel.prompt = "添加"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                self?.add(panel.urls)
            }
        }
    }

    private func add(_ urls: [URL]) {
        var added = false
        var invalidName: String?
        for url in urls {
            guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier,
                bundleIdentifier != Bundle.main.bundleIdentifier
            else {
                invalidName = url.lastPathComponent
                continue
            }
            added = bundleIdentifiers.insert(bundleIdentifier).inserted || added
        }
        if added {
            onChange?(bundleIdentifiers)
            reload()
        }
        if let invalidName {
            let alert = NSAlert()
            alert.messageText = "无法添加 App"
            alert.informativeText = "“\(invalidName)”没有可用的 Bundle Identifier。"
            alert.alertStyle = .informational
            alert.beginSheetModal(for: window)
        }
    }

    @objc private func removeApplications() {
        let identifiers = tableView.selectedRowIndexes.compactMap { index in
            rows.indices.contains(index) ? rows[index].bundleIdentifier : nil
        }
        guard !identifiers.isEmpty else { return }
        bundleIdentifiers.subtract(identifiers)
        onChange?(bundleIdentifiers)
        reload()
    }
}
