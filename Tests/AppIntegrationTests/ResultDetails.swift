import AppKit
import SwiftUI
import IndexCore

@main struct ResultDetailsTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let suite = "EverythingMac.ResultDetailsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = FileRecord(id: 2, name: "report.pdf", path: "/Docs/report.pdf", parent: 1,
                                  size: 32, mtime: 1, isDir: false, volID: 1)
        var sortCallbacks = 0
        let parent = ResultsTable(rows: [original], onSort: { _, _ in sortCallbacks += 1 }, onSelect: { _ in },
                                  onActivate: { _ in }, selectedRecords: [original], query: Query(text: "report"))
        let coordinator = ResultsTable.Coordinator(parent, columnDefaults: defaults)
        let table = NSTableView()
        coordinator.table = table
        coordinator.installColumns(in: table)
        table.dataSource = coordinator; table.delegate = coordinator
        precondition(table.tableColumns.count == ResultColumnKey.allCases.count)
        let files = table.tableColumns.first { $0.identifier.rawValue == "fileCount" }!
        precondition(files.isHidden)
        coordinator.updateColumnMenu()
        let item = coordinator.columnsMenu!.items.first { $0.representedObject as? String == "fileCount" }!
        coordinator.toggleColumn(item)
        precondition(!files.isHidden)
        table.moveColumn(5, toColumn: 0)
        files.width = 177
        coordinator.persistColumns()
        let saved = ResultsColumnLayout.load(from: defaults)
        precondition(saved.columns.first?.key == .fileCount)
        precondition(saved.columns.first?.width == 177 && saved.columns.first?.hidden == false)
        let restored = ResultsTable.Coordinator(parent, columnDefaults: defaults)
        let restoredTable = NSTableView(); restored.table = restoredTable
        restored.installColumns(in: restoredTable)
        precondition(restoredTable.tableColumns.first?.identifier.rawValue == "fileCount")
        precondition(restoredTable.tableColumns.first?.width == 177)
        precondition(restoredTable.tableColumns.first?.isHidden == false)
        for column in table.tableColumns where !column.isHidden {
            let toggle = NSMenuItem()
            toggle.representedObject = column.identifier.rawValue
            coordinator.toggleColumn(toggle)
        }
        precondition(table.tableColumns.filter { !$0.isHidden }.count == 1)
        table.tableColumns.first { $0.identifier.rawValue == "name" }?.isHidden = false
        coordinator.persistColumns()

        var totalParent = parent
        totalParent.showIndexedTotals = true
        var totalsVisible: Bool?
        totalParent.onIndexedTotalsVisibilityChanged = { totalsVisible = $0 }
        coordinator.reload(totalParent)
        let indexed = table.tableColumns.first { $0.identifier.rawValue == "indexedSize" }!
        precondition(!files.isHidden && !indexed.isHidden)
        let hideFiles = NSMenuItem(); hideFiles.representedObject = "fileCount"
        coordinator.toggleColumn(hideFiles)
        precondition(files.isHidden && !indexed.isHidden, "Hiding one totals column must not force the other")
        for _ in 0..<100 where totalsVisible == nil { await Task.yield() }
        precondition(totalsVisible == true)
        let hideIndexed = NSMenuItem(); hideIndexed.representedObject = "indexedSize"
        coordinator.toggleColumn(hideIndexed)
        for _ in 0..<100 where totalsVisible != false { await Task.yield() }
        precondition(totalsVisible == false)

        coordinator.reload(parent)
        precondition(coordinator.selectedRecords() == [original])
        await coordinator.highlightTask?.value
        precondition(coordinator.selectedRecords() == [original], "Highlight repaint must preserve selection")
        var sortedParent = parent
        sortedParent.sortKey = .mtime; sortedParent.ascending = false
        coordinator.reload(sortedParent)
        precondition(table.sortDescriptors.first?.key == "mtime" && table.sortDescriptors.first?.ascending == false)
        sortedParent.sortKey = .relevance
        coordinator.reload(sortedParent)
        precondition(table.sortDescriptors.isEmpty)
        precondition(sortCallbacks == 0, "Model sort restoration must not trigger another search")
        let nameColumn = table.tableColumns.first { $0.identifier.rawValue == "name" }!
        let cell = coordinator.tableView(table, viewFor: nameColumn, row: 0) as! NSTableCellView
        precondition(cell.textField?.stringValue == original.name)
        precondition(cell.textField?.attributedStringValue.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
        var changedQuery = parent; changedQuery.query = Query(text: "pdf")
        coordinator.reload(changedQuery)
        await coordinator.highlightTask?.value
        let changedCell = coordinator.tableView(table, viewFor: nameColumn, row: 0) as! NSTableCellView
        precondition(changedCell.textField?.attributedStringValue.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
        precondition(changedCell.textField?.attributedStringValue.attribute(.backgroundColor, at: 7, effectiveRange: nil) != nil)
        var replacement = parent
        replacement.selectedRecords = nil
        replacement.rows = [FileRecord(id: original.id, name: original.name, path: "/Other/report.pdf", parent: 1,
                                       size: 32, mtime: 1, isDir: false, volID: 1)]
        coordinator.reload(replacement)
        precondition(coordinator.selectedRecords().isEmpty, "Reused slot IDs must not select another path")
        coordinator.highlightTask?.cancel()

        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 1000, mtime: 0, isDir: true, volID: 1)
        let folder = store.append(name: "Docs", parent: root, size: 1000, mtime: 0, isDir: true, volID: 1)
        _ = store.append(name: "report.pdf", parent: folder, size: 32, mtime: 0, isDir: false, volID: 1)
        let index = SearchIndex(); index.publish(store)
        let model = FolderDetailsModel(index: index)
        model.refresh()
        // Await the same cached immutable build, then give the MainActor model its completion.
        let snapshot = await index.folderSnapshot()!
        for _ in 0..<100 where model.snapshot == nil { await Task.yield() }
        precondition(model.snapshot?.snapshotID == snapshot.snapshotID)
        var folders = parent
        folders.rows = [snapshot.record(for: folder)!]
        folders.folderTotals = snapshot; folders.query = nil; folders.selectedRecords = nil
        coordinator.reload(folders)
        let countCell = coordinator.tableView(table, viewFor: files, row: 0) as! NSTableCellView
        precondition(countCell.textField?.stringValue == "1")
        let metadataColumn = table.tableColumns.first { $0.identifier.rawValue == "size" }!
        let metadataCell = coordinator.tableView(table, viewFor: metadataColumn, row: 0) as! NSTableCellView
        precondition(metadataCell.textField?.stringValue == ByteCountFormatter.string(fromByteCount: 1000, countStyle: .file))
        let sizeColumn = table.tableColumns.first { $0.identifier.rawValue == "indexedSize" }!
        let sizeCell = coordinator.tableView(table, viewFor: sizeColumn, row: 0) as! NSTableCellView
        precondition(sizeCell.textField?.stringValue == ByteCountFormatter.string(fromByteCount: 32, countStyle: .file))
        model.cancel()
        let sidebar = FolderSidebarView(snapshot: snapshot, selectedScope: FolderScope(record: folders.rows[0]), onSelect: { _ in })
        _ = NSHostingView(rootView: sidebar)

        defaults.set(Data("bad-json".utf8), forKey: ResultsColumnLayout.defaultsKey)
        precondition(ResultsColumnLayout.load(from: defaults) == .standard)
        let malformed = ResultsColumnLayout(columns: [.init(key: .name, width: .infinity, hidden: true),
                                                      .init(key: .name, width: 1, hidden: true)])
        let sanitized = malformed.sanitized()
        precondition(sanitized.columns.count == ResultColumnKey.allCases.count)
        precondition(sanitized.columns.first?.width == ResultColumnKey.name.defaultWidth)
        precondition(sanitized.columns.contains { !$0.hidden })
    }
}
