import AppKit
import SwiftUI
import IndexCore

@MainActor private final class MultiClickedTable: NSTableView {
    var simulatedClickedRow = 0
    override var clickedRow: Int { simulatedClickedRow }
}

@main struct FileActions {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("file-actions-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let trash = root.appendingPathComponent("trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: false)
        let engine = FileOperationEngine { source in
            let destination = trash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
        func file(_ name: String, _ text: String = "original") throws -> URL {
            let url = root.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        func contents(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
        func require(_ condition: @autoclosure () throws -> Bool, _ message: String = "") throws {
            let passed = try condition()
            precondition(passed, message)
        }
        func record(_ id: UInt32, _ url: URL) -> FileRecord {
            FileRecord(id: id, name: url.lastPathComponent, path: url.path, parent: 0,
                       size: 8, mtime: 1, isDir: false, volID: 1)
        }

        let original = try file("original.txt")
        let copied = root.appendingPathComponent("copied.txt")
        var outcome = await engine.perform(.copy([FileTransfer(source: original, destination: copied)]))
        precondition(outcome.errors.isEmpty && outcome.changed == 1 && outcome.canUndo)
        try require(try contents(copied) == "original")
        outcome = await engine.undo()
        precondition(outcome.errors.isEmpty && outcome.changed == 1 && !outcome.canUndo)
        precondition(!fm.fileExists(atPath: copied.path) && fm.fileExists(atPath: original.path))

        let moved = root.appendingPathComponent("moved.txt")
        outcome = await engine.perform(.move([FileTransfer(source: original, destination: moved)]))
        precondition(outcome.errors.isEmpty && !fm.fileExists(atPath: original.path))
        outcome = await engine.undo()
        precondition(outcome.errors.isEmpty && fm.fileExists(atPath: original.path))
        outcome = await engine.perform(.trash([original]))
        precondition(outcome.errors.isEmpty && !fm.fileExists(atPath: original.path))
        outcome = await engine.undo()
        precondition(outcome.errors.isEmpty && fm.fileExists(atPath: original.path))

        let collision = try file("collision.txt", "keep me")
        outcome = await engine.perform(.copy([FileTransfer(source: original, destination: collision)]))
        precondition(outcome.changed == 0 && !outcome.errors.isEmpty)
        try require(try contents(collision) == "keep me")
        let missing = root.appendingPathComponent("missing.txt")
        outcome = await engine.perform(.move([FileTransfer(source: missing, destination: copied)]))
        precondition(outcome.changed == 0 && !outcome.errors.isEmpty && !fm.fileExists(atPath: copied.path))

        let swapA = try file("swap-a.txt", "A")
        let swapB = try file("swap-b.txt", "B")
        outcome = await engine.perform(.rename([FileTransfer(source: swapA, destination: swapB),
                                               FileTransfer(source: swapB, destination: swapA)]))
        precondition(outcome.errors.isEmpty && outcome.changed == 2)
        try require(try contents(swapA) == "B" && contents(swapB) == "A")
        outcome = await engine.undo()
        precondition(outcome.errors.isEmpty && outcome.changed == 2)
        try require(try contents(swapA) == "A" && contents(swapB) == "B")

        let caseFile = try file("case.txt")
        let caseRenamed = root.appendingPathComponent("CASE.txt")
        outcome = await engine.perform(.rename([FileTransfer(source: caseFile, destination: caseRenamed)]))
        precondition(outcome.errors.isEmpty && fm.fileExists(atPath: caseRenamed.path))
        outcome = await engine.undo()
        precondition(outcome.errors.isEmpty && fm.fileExists(atPath: caseFile.path))

        outcome = await engine.perform(.copy([FileTransfer(source: original, destination: copied)]))
        precondition(outcome.errors.isEmpty)
        try "edited after copy".write(to: copied, atomically: true, encoding: .utf8)
        outcome = await engine.undo()
        precondition(!outcome.errors.isEmpty && outcome.changed == 0 && outcome.canUndo)
        try require(try contents(copied) == "edited after copy", "Undo must retain files edited after the operation")

        let moveEngine = FileOperationEngine()
        let protectedSource = try file("protected.txt")
        let protectedMoved = root.appendingPathComponent("protected-moved.txt")
        outcome = await moveEngine.perform(.move([FileTransfer(source: protectedSource, destination: protectedMoved)]))
        precondition(outcome.errors.isEmpty)
        _ = try file("protected.txt", "new file")
        outcome = await moveEngine.undo()
        precondition(!outcome.errors.isEmpty && outcome.changed == 0)
        try require(try contents(protectedSource) == "new file" && contents(protectedMoved) == "original")

        let folder = root.appendingPathComponent("folder")
        let folderCopy = root.appendingPathComponent("folder-copy")
        try fm.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "child".write(to: folder.appendingPathComponent("nested/child.txt"), atomically: true, encoding: .utf8)
        let folderEngine = FileOperationEngine { source in
            let destination = trash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
        outcome = await folderEngine.perform(.copy([FileTransfer(source: folder, destination: folderCopy)]))
        precondition(outcome.errors.isEmpty)
        try "changed child".write(to: folderCopy.appendingPathComponent("nested/child.txt"), atomically: true, encoding: .utf8)
        outcome = await folderEngine.undo()
        precondition(!outcome.errors.isEmpty && outcome.changed == 0)
        precondition(fm.fileExists(atPath: folderCopy.path), "Undo must check children, not only the folder's inode")

        let alias = root.appendingPathComponent("folder-alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: folder)
        let nestedCopy = alias.appendingPathComponent("nested-copy")
        outcome = await engine.perform(.copy([FileTransfer(source: folder, destination: nestedCopy)]))
        precondition(!outcome.errors.isEmpty && outcome.changed == 0 && !fm.fileExists(atPath: nestedCopy.path),
                     "A directory must not be copied into itself through a symlink alias")
        let linkCopy = root.appendingPathComponent("copied-link")
        outcome = await engine.perform(.copy([FileTransfer(source: alias, destination: linkCopy)]))
        precondition(outcome.errors.isEmpty && outcome.changed == 1)
        try require(try fm.destinationOfSymbolicLink(atPath: linkCopy.path) == folder.path)
        outcome = await engine.undo()
        precondition(outcome.errors.isEmpty && !fm.fileExists(atPath: linkCopy.path) && fm.fileExists(atPath: folder.path))
        outcome = await engine.perform(.trash([folder, alias.appendingPathComponent("nested/child.txt")]))
        precondition(!outcome.errors.isEmpty && outcome.changed == 0,
                     "Nested source selections must be rejected before moving a parent")

        var rule = BatchRenameRule()
        rule.mode = .number
        rule.prefix = "photo-"
        rule.start = 7
        let records = [record(1, original), record(2, collision)]
        let numbered = try rule.transfers(for: records)
        precondition(numbered.map(\.destination.lastPathComponent) == ["photo-7.txt", "photo-8.txt"])
        rule.mode = .replace
        rule.find = "original"
        rule.replacement = "new"
        try require(try rule.transfers(for: records).map(\.destination.lastPathComponent) == ["new.txt"])
        rule.mode = .addText
        rule.prefix = "bad/name"
        do { _ = try rule.transfers(for: records); preconditionFailure("Slash-containing names must be rejected") }
        catch { }
        let duplicateTargets = [FileTransfer(source: original, destination: missing),
                                FileTransfer(source: collision, destination: missing)]
        outcome = await engine.perform(.rename(duplicateTargets))
        precondition(outcome.changed == 0 && !outcome.errors.isEmpty)
        precondition(fm.fileExists(atPath: original.path) && fm.fileExists(atPath: collision.path))

        var picked: [FileRecord] = []
        func view(_ rows: [FileRecord]) -> ResultsTable {
            ResultsTable(rows: rows, onSort: { _, _ in }, onSelect: { _ in }, onActivate: { _ in },
                         onSelection: { picked = $0 })
        }
        let table = MultiClickedTable()
        table.allowsMultipleSelection = true
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        let coordinator = ResultsTable.Coordinator(view(records))
        coordinator.table = table
        table.dataSource = coordinator
        table.delegate = coordinator
        table.reloadData()
        table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        precondition(picked == records)
        let menu = NSMenu()
        coordinator.contextMenu = menu
        table.simulatedClickedRow = 1
        coordinator.menuNeedsUpdate(menu)
        precondition(coordinator.clickedRecords() == records)
        coordinator.reload(view(records.reversed()))
        precondition(table.selectedRowIndexes == IndexSet([0, 1]))
        precondition(coordinator.clickedRecords() == records, "Menu actions must keep the original selected paths")
        coordinator.reload(view([record(1, missing), records[1]]))
        precondition(table.selectedRowIndexes == IndexSet(integer: 1), "Reused numeric IDs must not retain other files")
        precondition(coordinator.tableView(table, pasteboardWriterForRow: 0) as? NSURL == missing as NSURL)
        precondition(coordinator.tableView(table, pasteboardWriterForRow: -1) == nil)

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        ResultActions.copyFiles(records, to: board)
        precondition(ResultActions.canPasteFiles(from: board))
        let fileURLs = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        precondition(fileURLs == records.map { URL(fileURLWithPath: $0.path) })
        let unusualPath = "/tmp/quoted\"\\name\nend tell.txt"
        precondition(FinderInfoRequest.arguments(for: [unusualPath]).last == unusualPath)
        precondition(!FinderInfoRequest.script.contains(unusualPath))
        print("PASS: copy/move/trash undo, changed-file protection, rename swaps/collisions, multi-selection and file-URL pasteboard")
    }
}
