import AppKit
import SwiftUI
import IndexCore

@main struct TableSafety {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("table-safety-\(UUID().uuidString).idx")
        defer { try? FileManager.default.removeItem(at: cache) }
        let table = NSTableView()
        let column = NSTableColumn(identifier: .init("size"))
        for bytes in [UInt64(0), 42, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max] {
            var store = FileStore()
            let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
            store.append(name: "report.pdf", parent: root, size: bytes, mtime: 123, isDir: false, volID: 1)
            try IndexCache.save(store, to: cache, lastEventID: 7, rulesFingerprint: 9)
            let loaded = try IndexCache.load(from: cache).0
            let index = SearchIndex()
            index.publish(loaded)
            let records = await index.search(Query(text: "report.pdf", fuzzy: false))
            precondition(records.count == 1 && records[0].size == bytes)
            let view = ResultsTable(rows: records, onSort: { _, _ in }, onSelect: { _ in }, onActivate: { _ in })
            let coordinator = ResultsTable.Coordinator(view)
            let cell = coordinator.tableView(table, viewFor: column, row: 0) as? NSTableCellView
            let expected: String
            if let signed = Int64(exactly: bytes) {
                expected = ByteCountFormatter.string(fromByteCount: signed, countStyle: .file)
            } else {
                expected = "\(bytes) \(UnitInformationStorage.bytes.symbol)"
            }
            precondition(cell?.textField?.stringValue == expected, "Cache size was lost or changed")
            // Recreate a queued row request after the same coordinator loses its rows.
            coordinator.parent = ResultsTable(rows: [], onSort: { _, _ in }, onSelect: { _ in }, onActivate: { _ in })
            for stale in [-1, 0, Int.max] {
                precondition(coordinator.tableView(table, viewFor: column, row: stale) == nil)
            }
        }
        print("PASS: cached UInt64 sizes render exactly and stale table rows are ignored")
    }
}
