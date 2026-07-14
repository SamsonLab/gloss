import AppKit
import GlossCore

@MainActor
final class GlossaryWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onChange: (() -> Void)?

    private let store: GlossaryStore
    private let window: NSWindow
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton(title: "−", target: nil, action: nil)
    private var terms: [GlossaryTerm] = []

    init(store: GlossaryStore) {
        self.store = store
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
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
        reload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        terms.count
    }

    func tableView(
        _ tableView: NSTableView,
        objectValueFor tableColumn: NSTableColumn?,
        row: Int
    ) -> Any? {
        guard terms.indices.contains(row), let tableColumn else { return nil }
        return tableColumn.identifier.rawValue == "source" ? terms[row].source : terms[row].target
    }

    func tableView(
        _ tableView: NSTableView,
        setObjectValue object: Any?,
        for tableColumn: NSTableColumn?,
        row: Int
    ) {
        guard terms.indices.contains(row), let tableColumn else { return }
        let value = (object as? String) ?? ""
        let current = terms[row]
        terms[row] =
            tableColumn.identifier.rawValue == "source"
            ? GlossaryTerm(source: value, target: current.target)
            : GlossaryTerm(source: current.source, target: value)
        showStatus("有未保存的更改", isError: false, muted: true)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = tableView.selectedRow >= 0
    }

    private func configureWindow() {
        window.title = "Gloss 术语表"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 360)

        let content = NSView()
        window.contentView = content

        let title = NSTextField(labelWithString: "术语表")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let explanation = NSTextField(
            wrappingLabelWithString:
                "Gloss 只会向翻译请求加入当前原文中实际出现的术语，最多 40 条。文件使用 Tab 分隔，可直接用文本工具维护。"
        )
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        explanation.translatesAutoresizingMaskIntoConstraints = false

        let sourceColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        sourceColumn.title = "原文术语"
        sourceColumn.minWidth = 180
        sourceColumn.isEditable = true
        let targetColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("target"))
        targetColumn.title = "指定译法"
        targetColumn.minWidth = 180
        targetColumn.isEditable = true
        tableView.addTableColumn(sourceColumn)
        tableView.addTableColumn(targetColumn)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.rowHeight = 28
        tableView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self

        let tableScroll = NSScrollView()
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.borderType = .bezelBorder
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(title: "+", target: self, action: #selector(addTerm))
        addButton.toolTip = "添加术语"
        removeButton.target = self
        removeButton.action = #selector(removeTerm)
        removeButton.toolTip = "移除所选术语"
        removeButton.isEnabled = false
        let rowButtons = NSStackView(views: [addButton, removeButton])
        rowButtons.orientation = .horizontal
        rowButtons.spacing = 0
        rowButtons.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let revealButton = NSButton(title: "在 Finder 中显示", target: self, action: #selector(revealFile))
        let saveButton = NSButton(title: "保存", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        let actionButtons = NSStackView(views: [revealButton, saveButton])
        actionButtons.orientation = .horizontal
        actionButtons.spacing = 8
        actionButtons.translatesAutoresizingMaskIntoConstraints = false

        for view in [title, explanation, tableScroll, rowButtons, statusLabel, actionButtons] {
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            explanation.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            explanation.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            explanation.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            tableScroll.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 16),
            tableScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            tableScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            tableScroll.bottomAnchor.constraint(equalTo: rowButtons.topAnchor, constant: -8),
            rowButtons.leadingAnchor.constraint(equalTo: tableScroll.leadingAnchor),
            rowButtons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            statusLabel.leadingAnchor.constraint(equalTo: rowButtons.trailingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: rowButtons.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionButtons.leadingAnchor, constant: -12),
            actionButtons.trailingAnchor.constraint(equalTo: tableScroll.trailingAnchor),
            actionButtons.centerYAnchor.constraint(equalTo: rowButtons.centerYAnchor),
        ])
    }

    private func reload() {
        Task { [weak self] in
            guard let self else { return }
            do {
                terms = try await store.reload()
                tableView.reloadData()
                removeButton.isEnabled = false
                showStatus(terms.isEmpty ? "尚未添加术语" : "已载入 \(terms.count) 条术语")
            } catch {
                showStatus(error.localizedDescription, isError: true)
            }
        }
    }

    private func saveTerms(revealAfterSaving: Bool = false) {
        window.makeFirstResponder(nil)
        let terms = self.terms
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.replace(with: terms)
                self.terms = try await store.terms()
                tableView.reloadData()
                showStatus("已保存 \(self.terms.count) 条术语")
                onChange?()
                if revealAfterSaving {
                    NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                }
            } catch {
                showStatus(error.localizedDescription, isError: true)
            }
        }
    }

    private func showStatus(_ message: String, isError: Bool = false, muted: Bool = false) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : (muted ? .secondaryLabelColor : .systemGreen)
    }

    @objc private func addTerm() {
        window.makeFirstResponder(nil)
        terms.append(GlossaryTerm(source: "", target: ""))
        tableView.reloadData()
        let row = terms.count - 1
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        tableView.editColumn(0, row: row, with: nil, select: true)
        showStatus("填写原文术语和指定译法后保存", muted: true)
    }

    @objc private func removeTerm() {
        window.makeFirstResponder(nil)
        let row = tableView.selectedRow
        guard terms.indices.contains(row) else { return }
        terms.remove(at: row)
        tableView.reloadData()
        removeButton.isEnabled = false
        showStatus("有未保存的更改", muted: true)
    }

    @objc private func save() {
        saveTerms()
    }

    @objc private func revealFile() {
        saveTerms(revealAfterSaving: true)
    }
}
