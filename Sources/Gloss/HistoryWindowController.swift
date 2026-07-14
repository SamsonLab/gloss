import AppKit
import GlossCore

@MainActor
final class HistoryWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onRetranslate: ((TranslationHistoryEntry) -> Void)?

    private let store: TranslationHistoryStore
    private let window: NSWindow
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "暂无记录")
    private let metadataLabel = NSTextField(labelWithString: "")
    private let sourceTextView = NSTextView()
    private let translatedTextView = NSTextView()
    private let copySourceButton = NSButton(title: "复制原文", target: nil, action: nil)
    private let copyTranslationButton = NSButton(title: "复制译文", target: nil, action: nil)
    private let retranslateButton = NSButton(title: "重新翻译", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除", target: nil, action: nil)
    private var entries: [TranslationHistoryEntry] = []
    private var filteredEntries: [TranslationHistoryEntry] = []

    init(store: TranslationHistoryStore) {
        self.store = store
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
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

    func reloadIfVisible() {
        guard window.isVisible else { return }
        reload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredEntries.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard filteredEntries.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("HistoryCell")
        let cell: NSTableCellView
        let detail: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView,
            let reusedDetail = reused.subviews.first(where: { $0.identifier?.rawValue == "detail" })
                as? NSTextField
        {
            cell = reused
            detail = reusedDetail
        } else {
            let created = makeHistoryCell(identifier: identifier)
            cell = created.cell
            detail = created.detail
        }

        let entry = filteredEntries[row]
        cell.textField?.stringValue = preview(entry.sourceText)
        cell.toolTip = entry.sourceText
        detail.stringValue = [
            TranslationLanguages.title(forTargetName: entry.targetLanguage),
            entry.sourceName,
            entry.createdAt.formatted(date: .abbreviated, time: .shortened),
        ].joined(separator: "  ·  ")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetail()
    }

    private func configureWindow() {
        window.title = "Gloss 翻译历史"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 420)

        let content = NSView()
        window.contentView = content

        searchField.placeholderString = "搜索原文或译文"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("History"))
        column.title = "历史"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 58
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.backgroundColor = .clear
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self

        let tableScroll = NSScrollView()
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.borderType = .noBorder
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        let clearButton = NSButton(title: "清空历史…", target: self, action: #selector(clearHistory))
        clearButton.bezelStyle = .inline
        clearButton.controlSize = .small
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let left = NSView()
        left.translatesAutoresizingMaskIntoConstraints = false
        for view in [searchField, tableScroll, emptyLabel, clearButton] {
            left.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: left.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -12),
            tableScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            tableScroll.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: clearButton.topAnchor, constant: -8),
            emptyLabel.centerXAnchor.constraint(equalTo: tableScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableScroll.centerYAnchor),
            clearButton.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 12),
            clearButton.bottomAnchor.constraint(equalTo: left.bottomAnchor, constant: -10),
        ])

        metadataLabel.font = .systemFont(ofSize: 12)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.translatesAutoresizingMaskIntoConstraints = false

        let sourceLabel = sectionLabel("原文")
        let translationLabel = sectionLabel("译文")
        let sourceScroll = textScrollView(for: sourceTextView)
        let translationScroll = textScrollView(for: translatedTextView)

        copySourceButton.target = self
        copySourceButton.action = #selector(copySource)
        copyTranslationButton.target = self
        copyTranslationButton.action = #selector(copyTranslation)
        retranslateButton.target = self
        retranslateButton.action = #selector(retranslate)
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        let actionButtons = NSStackView(views: [
            deleteButton, retranslateButton, copySourceButton, copyTranslationButton,
        ])
        actionButtons.orientation = .horizontal
        actionButtons.alignment = .centerY
        actionButtons.spacing = 8
        actionButtons.translatesAutoresizingMaskIntoConstraints = false

        let right = NSView()
        right.translatesAutoresizingMaskIntoConstraints = false
        for view in [metadataLabel, sourceLabel, sourceScroll, translationLabel, translationScroll, actionButtons] {
            right.addSubview(view)
        }
        NSLayoutConstraint.activate([
            metadataLabel.topAnchor.constraint(equalTo: right.topAnchor, constant: 15),
            metadataLabel.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 16),
            metadataLabel.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -16),
            sourceLabel.topAnchor.constraint(equalTo: metadataLabel.bottomAnchor, constant: 14),
            sourceLabel.leadingAnchor.constraint(equalTo: metadataLabel.leadingAnchor),
            sourceScroll.topAnchor.constraint(equalTo: sourceLabel.bottomAnchor, constant: 6),
            sourceScroll.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 12),
            sourceScroll.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -12),
            sourceScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            translationLabel.topAnchor.constraint(equalTo: sourceScroll.bottomAnchor, constant: 13),
            translationLabel.leadingAnchor.constraint(equalTo: metadataLabel.leadingAnchor),
            translationScroll.topAnchor.constraint(equalTo: translationLabel.bottomAnchor, constant: 6),
            translationScroll.leadingAnchor.constraint(equalTo: sourceScroll.leadingAnchor),
            translationScroll.trailingAnchor.constraint(equalTo: sourceScroll.trailingAnchor),
            translationScroll.heightAnchor.constraint(equalTo: sourceScroll.heightAnchor),
            translationScroll.bottomAnchor.constraint(equalTo: actionButtons.topAnchor, constant: -12),
            actionButtons.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -12),
            actionButtons.bottomAnchor.constraint(equalTo: right.bottomAnchor, constant: -12),
        ])

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(left)
        splitView.addArrangedSubview(right)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: content.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            left.widthAnchor.constraint(lessThanOrEqualToConstant: 330),
            right.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])
        splitView.setPosition(270, ofDividerAt: 0)
        updateDetail()
    }

    private func makeHistoryCell(
        identifier: NSUserInterfaceItemIdentifier
    ) -> (cell: NSTableCellView, detail: NSTextField) {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = title

        let detail = NSTextField(labelWithString: "")
        detail.identifier = NSUserInterfaceItemIdentifier("detail")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(title)
        cell.addSubview(detail)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 9),
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
        ])
        return (cell, detail)
    }

    private func sectionLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func textScrollView(for textView: NSTextView) -> NSScrollView {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 9, height: 9)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 8
        scrollView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return scrollView
    }

    private func reload() {
        let selectedID = selectedEntry?.id
        Task { [weak self] in
            guard let self else { return }
            do {
                entries = try await store.entries()
                applyFilter(selecting: selectedID)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    private func applyFilter(selecting selectedID: UUID? = nil) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
        if query.isEmpty {
            filteredEntries = entries
        } else {
            filteredEntries = entries.filter { entry in
                [entry.sourceText, entry.translatedText, entry.sourceName, entry.targetLanguage]
                    .contains { $0.localizedLowercase.contains(query) }
            }
        }
        tableView.reloadData()
        emptyLabel.stringValue = entries.isEmpty ? "暂无记录" : "没有匹配记录"
        emptyLabel.isHidden = !filteredEntries.isEmpty

        let row =
            selectedID.flatMap { id in filteredEntries.firstIndex { $0.id == id } }
            ?? (filteredEntries.isEmpty ? nil : 0)
        if let row {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else {
            tableView.deselectAll(nil)
            updateDetail()
        }
    }

    private var selectedEntry: TranslationHistoryEntry? {
        let row = tableView.selectedRow
        guard filteredEntries.indices.contains(row) else { return nil }
        return filteredEntries[row]
    }

    private func updateDetail() {
        guard let entry = selectedEntry else {
            metadataLabel.stringValue = entries.isEmpty ? "还没有翻译历史" : "选择一条记录"
            sourceTextView.string = ""
            translatedTextView.string = ""
            setActionButtons(enabled: false)
            return
        }

        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.stringValue = [
            entry.sourceName,
            TranslationLanguages.title(forTargetName: entry.targetLanguage),
            entry.profile.displayName,
            entry.createdAt.formatted(date: .abbreviated, time: .shortened),
        ].joined(separator: "  ·  ")
        sourceTextView.string = entry.sourceText
        translatedTextView.string = entry.translatedText
        setActionButtons(enabled: true)
    }

    private func setActionButtons(enabled: Bool) {
        copySourceButton.isEnabled = enabled
        copyTranslationButton.isEnabled = enabled
        retranslateButton.isEnabled = enabled
        deleteButton.isEnabled = enabled
    }

    private func showError(_ message: String) {
        metadataLabel.stringValue = message
        metadataLabel.textColor = .systemRed
        sourceTextView.string = ""
        translatedTextView.string = ""
        setActionButtons(enabled: false)
    }

    private func preview(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func searchChanged() {
        applyFilter(selecting: selectedEntry?.id)
    }

    @objc private func copySource() {
        guard let entry = selectedEntry else { return }
        SelectionWriter.copy(entry.sourceText)
        metadataLabel.stringValue = "已复制原文"
        metadataLabel.textColor = .systemGreen
    }

    @objc private func copyTranslation() {
        guard let entry = selectedEntry else { return }
        SelectionWriter.copy(entry.translatedText)
        metadataLabel.stringValue = "已复制译文"
        metadataLabel.textColor = .systemGreen
    }

    @objc private func retranslate() {
        guard let entry = selectedEntry else { return }
        window.orderOut(nil)
        onRetranslate?(entry)
    }

    @objc private func deleteSelected() {
        guard let entry = selectedEntry else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.delete(id: entry.id)
                reload()
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    @objc private func clearHistory() {
        guard !entries.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "清空翻译历史？"
        alert.informativeText = "这会永久删除保存在本机的全部 Gloss 翻译记录。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { @MainActor in
                do {
                    try await self.store.clear()
                    self.reload()
                } catch {
                    self.showError(error.localizedDescription)
                }
            }
        }
    }
}
