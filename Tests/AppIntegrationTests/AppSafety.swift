import AppKit
import SwiftUI
import IndexCore

@MainActor private final class ClickedTable: NSTableView {
    var simulatedClickedRow = 0
    override var clickedRow: Int { simulatedClickedRow }
}

@main struct AppSafety {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let suite = "app-safety-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let index = IndexActor(rules: .defaults)
        let model = AppModel(index: index, preferences: preferences)
        func record(_ id: UInt32, _ path: String) -> FileRecord {
            FileRecord(id: id, name: (path as NSString).lastPathComponent, path: path,
                       parent: 0, size: 42, mtime: 123, isDir: false, volID: 1)
        }
        let first = record(1, "/fixture/first.txt")
        let second = record(2, "/fixture/second.txt")
        let reused = record(1, "/fixture/different.txt")
        model.results = [first, second]
        model.selectedID = first.id
        precondition(model.selected == first)
        model.results = [second, first]
        precondition(model.selected == first, "Reordering must preserve the selected file")
        model.results = [reused, second]
        precondition(model.selectedID == nil && model.selected == nil,
                     "A rebuilt index reused an ID and redirected Open/Trash to another path")
        model.results = [first, second]
        model.selectedID = first.id
        model.results = [second]
        precondition(model.selected == nil)

        model.results = [first, second]
        model.selectRecords([first, second])
        precondition(model.selectedRecords == [first, second])
        model.results = [second, first]
        precondition(model.selectedRecords.map(\.path) == [first.path, second.path])
        model.results = [second, reused]
        precondition(model.selectedRecords == [second], "ID reuse redirected a multiple-file operation")

        let composed = record(9, "/fixture/caf\u{E9}.txt")
        let decomposed = record(9, "/fixture/cafe\u{301}.txt")
        precondition(!composed.path.utf8.elementsEqual(decomposed.path.utf8))
        model.results = [composed]
        model.selectedID = composed.id
        model.results = [decomposed]
        precondition(model.selectedID == nil && model.selected == nil,
                     "Canonically equivalent path text redirected actions to different path bytes")
        model.results = [composed]
        model.selectRecords([composed])
        model.results = [decomposed]
        precondition(model.selectedRecords.isEmpty, "Multiple selection accepted a different Unicode path")

        func tableView(_ rows: [FileRecord]) -> ResultsTable {
            ResultsTable(rows: rows, onSort: { _, _ in }, onSelect: { _ in }, onActivate: { _ in })
        }
        let table = ClickedTable()
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        let coordinator = ResultsTable.Coordinator(tableView([first, second]))
        coordinator.table = table
        table.dataSource = coordinator
        table.delegate = coordinator
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        coordinator.reload(tableView([reused, second]))
        precondition(table.selectedRow == -1, "Numeric ID reuse left an unrelated file highlighted")
        coordinator.reload(tableView([first, second]))
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        coordinator.reload(tableView([second, first]))
        precondition(table.selectedRow == 1)

        let menu = NSMenu()
        coordinator.contextMenu = menu
        table.simulatedClickedRow = 1
        coordinator.menuNeedsUpdate(menu)
        precondition(coordinator.clickedRecord() == first)
        coordinator.reload(tableView([first, reused]))
        precondition(coordinator.clickedRecord() == first,
                     "A live refresh redirected a context-menu action to the new clickedRow")
        table.simulatedClickedRow = -1
        coordinator.menuNeedsUpdate(menu)
        precondition(coordinator.clickedRecord() == nil)

        coordinator.reload(tableView([composed]))
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        coordinator.reload(tableView([decomposed]))
        precondition(table.selectedRow == -1, "Selection survived replacement by different Unicode path bytes")

        let unusual = record(7, "/fixture/tab\tline\n\"quoted\".txt")
        let exported = ResultActions.exportedTSV([unusual])
        precondition(exported.contains("\"tab\tline\n\"\"quoted\"\".txt\"\t\"/fixture/tab\tline\n\"\"quoted\"\".txt\""),
                     "TSV must preserve filename delimiters with standard quoted fields")
        print("PASS: selection and menu targets stay on their original paths; TSV preserves delimiters")
    }
}
