import AppKit
import IndexCore

extension ResultsTable.Coordinator {
    func applyIndexedTotalsOverride() {
        guard let visible = parent.showIndexedTotals, let table else { return }
        for column in table.tableColumns where column.identifier.rawValue == "indexedSize" || column.identifier.rawValue == "fileCount" {
            column.isHidden = !visible
        }
        if table.tableColumns.allSatisfy(\.isHidden) {
            table.tableColumns.first { $0.identifier.rawValue == "name" }?.isHidden = false
        }
        persistColumns()
    }

    func notifyIndexedTotalsVisibility() {
        guard let table else { return }
        let visible = table.tableColumns.contains {
            !$0.isHidden && ($0.identifier.rawValue == "indexedSize" || $0.identifier.rawValue == "fileCount")
        }
        guard lastIndexedTotalsVisibility != visible else { return }
        lastIndexedTotalsVisibility = visible
        // Initial callbacks run after SwiftUI has completed the representable update.
        Task { [weak self] in
            guard let self, self.lastIndexedTotalsVisibility == visible else { return }
            self.parent.onIndexedTotalsVisibilityChanged?(visible)
        }
    }

    func applySortIndicators() {
        guard let table, let sort = parent.sortKey else { return }
        let key: String?
        switch sort {
        case .relevance: key = nil
        case .name: key = "name"
        case .path: key = "path"
        case .size: key = "size"
        case .kind: key = "kind"
        case .mtime: key = "mtime"
        }
        let next = key.map { [NSSortDescriptor(key: $0, ascending: parent.ascending)] } ?? []
        guard table.sortDescriptors != next else { return }
        suppressSortCallback = true
        defer { suppressSortCallback = false }
        table.sortDescriptors = next
    }

    func installColumns(in table: NSTableView) {
        suppressColumnPersistence = true
        defer {
            suppressColumnPersistence = false
            if parent.showIndexedTotals != nil { persistColumns() }
            notifyIndexedTotalsVisibility()
        }
        for saved in columnLayout.columns {
            let column = NSTableColumn(identifier: .init(saved.key.rawValue))
            column.title = saved.key.title
            column.width = saved.width
            column.minWidth = 40
            column.maxWidth = 2000
            column.isHidden = saved.hidden
            if saved.key != .fileCount && saved.key != .indexedSize {
                column.sortDescriptorPrototype = NSSortDescriptor(key: saved.key.rawValue, ascending: true)
            }
            table.addTableColumn(column)
        }
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        let menu = NSMenu()
        menu.delegate = self
        columnsMenu = menu
        table.headerView?.menu = menu
        applyIndexedTotalsOverride()
        updateColumnMenu()
    }

    func updateColumnMenu() {
        guard let columnsMenu, let table else { return }
        columnsMenu.removeAllItems()
        let visible = table.tableColumns.filter { !$0.isHidden }.count
        for column in table.tableColumns {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.identifier.rawValue
            item.state = column.isHidden ? .off : .on
            item.isEnabled = column.isHidden || visible > 1
            columnsMenu.addItem(item)
        }
    }

    @objc func toggleColumn(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let column = table?.tableColumns.first(where: { $0.identifier.rawValue == key }) else { return }
        if !column.isHidden && table?.tableColumns.filter({ !$0.isHidden }).count == 1 { return }
        column.isHidden.toggle()
        persistColumns()
    }

    func persistColumns() {
        guard !suppressColumnPersistence, let table else { return }
        columnLayout = ResultsColumnLayout(columns: table.tableColumns.compactMap { column in
            guard let key = ResultColumnKey(rawValue: column.identifier.rawValue) else { return nil }
            return .init(key: key, width: column.width, hidden: column.isHidden)
        }).sanitized()
        columnLayout.save(to: columnDefaults)
        notifyIndexedTotalsVisibility()
    }

    func tableViewColumnDidMove(_ notification: Notification) { persistColumns() }
    func tableViewColumnDidResize(_ notification: Notification) { persistColumns() }
}
