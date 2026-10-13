import AppKit
import SwiftUI
import IndexCore

private actor FolderSnapshotSequence {
    private var snapshots: [FolderSnapshot?]
    private(set) var reads = 0
    init(_ snapshots: [FolderSnapshot?]) { self.snapshots = snapshots }
    func next() -> FolderSnapshot? {
        reads += 1
        return snapshots.isEmpty ? nil : snapshots.removeFirst()
    }
}

@main struct FolderSidebarRefreshTests {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                let failures = try await verifySnapshotRetention() + verifyNativeRefresh()
                try require(failures.isEmpty, failures.joined(separator: "; "))
                print("PASS: canceled and repeated folder loads retain the tree; background file updates preserve selected rows, cells and scroll position")
                exit(EXIT_SUCCESS)
            } catch {
                print("FAIL: \(error.localizedDescription)")
                exit(EXIT_FAILURE)
            }
        }
        NSApplication.shared.run()
    }

    @MainActor private static func verifySnapshotRetention() async throws -> [String] {
        let index = SearchIndex()
        index.publish(fixture())
        guard let first = await index.folderSnapshot() else { throw failure("Initial fixture snapshot missing") }
        index.publish(FileStore())
        guard let empty = await index.folderSnapshot() else { throw failure("Empty fixture snapshot missing") }
        let sequence = FolderSnapshotSequence([first, nil, first, empty])
        let details = FolderDetailsModel(index: index, loadSnapshot: { _ in await sequence.next() })
        var publications = 0
        let subscription = details.$snapshot.sink { _ in publications += 1 }
        defer { subscription.cancel() }
        details.refresh()
        try await waitUntil { details.snapshot?.snapshotID == first.snapshotID }
        let initialPublications = publications
        details.refresh()
        try await waitForReads(2, sequence: sequence)
        var failures: [String] = []
        if details.snapshot?.snapshotID != first.snapshotID {
            failures.append("A canceled folder load cleared the existing tree")
        }
        details.refresh()
        try await waitForReads(3, sequence: sequence)
        if publications != initialPublications {
            failures.append("A repeated folder snapshot unnecessarily republished the tree")
        }
        details.refresh()
        try await waitUntil { details.snapshot?.snapshotID == empty.snapshotID }
        try require(details.snapshot?.roots.isEmpty == true, "A valid empty index retained stale folders")
        print("CHECK: canceled/repeated snapshot failures=\(failures.count)")
        return failures
    }

    @MainActor private static func verifyNativeRefresh() async throws -> [String] {
        let index = SearchIndex()
        var store = fixture()
        index.publish(store)
        guard let snapshot = await index.folderSnapshot() else { throw failure("Native fixture snapshot missing") }
        let state = FolderSidebarState()
        let selection = FolderSearchScope(included: [FolderScope(path: "/Folder20"), FolderScope(path: "/Folder21")])
        var modelWrites = 0
        func root(_ snapshot: FolderSnapshot, selection: FolderSearchScope?) -> FolderOutlineView {
            FolderOutlineView(snapshot: snapshot, selection: selection, state: state, onSelect: { _ in modelWrites += 1 })
        }
        let host = NSHostingView(rootView: root(snapshot, selection: selection))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await settle(host)
        guard let outline = descendants(host).compactMap({ $0 as? FolderOutlineTable }).first else {
            throw failure("Native outline missing")
        }
        let selected = outline.selectedRowIndexes
        try require(selected.count == 2, "Fixture multi-selection failed")
        outline.scrollRowToVisible(selected.last!)
        try await settle(host)
        let visibleRows = outline.rows(in: outline.visibleRect)
        try require(selected.allSatisfy { NSLocationInRange($0, visibleRows) }, "Selected fixture cells are outside the viewport")
        let nodes = selected.compactMap { outline.item(atRow: $0) as? FolderOutlineItem }
        let cells = selected.compactMap { outline.view(atColumn: 0, row: $0, makeIfNecessary: true) }
        let scroll = outline.enclosingScrollView!.contentView.bounds.origin
        var failures: [String] = []
        for update in 0..<4 {
            store.append(name: "background-\(update).txt", parent: 0, size: 1, mtime: 0, isDir: false, volID: 1)
            index.publish(store)
            guard let next = await index.folderSnapshot() else { throw failure("Updated folder snapshot missing") }
            host.rootView = root(next, selection: selection)
            try await settle(host)
            let currentNodes = selected.compactMap { outline.item(atRow: $0) as? FolderOutlineItem }
            let currentCells = selected.compactMap { outline.view(atColumn: 0, row: $0, makeIfNecessary: true) }
            if !zip(nodes, currentNodes).allSatisfy({ $0 === $1 }) || currentNodes.count != nodes.count {
                failures.append("File-only publication \(update) recreated selected directory items")
            }
            if !zip(cells, currentCells).allSatisfy({ $0 === $1 }) || currentCells.count != cells.count {
                failures.append("File-only publication \(update) replaced selected native cells")
            }
            try require(outline.selectedRowIndexes == selected, "Background file update changed selected rows")
            try require(abs(outline.enclosingScrollView!.contentView.bounds.origin.y-scroll.y) < 1,
                        "Background file update moved the folder scroll position")
        }
        try require(modelWrites == 0, "Programmatic refresh changed the search scope")
        guard let selectedParent = nodes.first else { throw failure("Selected parent missing") }
        let child = store.append(name: "Child", parent: selectedParent.record.id, size: 0, mtime: 0, isDir: true, volID: 1)
        index.publish(store)
        guard let childSnapshot = await index.folderSnapshot() else { throw failure("Child fixture snapshot missing") }
        let deepSelection = FolderSearchScope(included: [FolderScope(path: "/Folder20/Child"), FolderScope(path: "/Folder21")])
        host.rootView = root(childSnapshot, selection: deepSelection)
        try await settle(host)
        guard let parentRow = (0..<outline.numberOfRows).first(where: {
            (outline.item(atRow: $0) as? FolderOutlineItem)?.record.path == "/Folder20"
        }), let parent = outline.item(atRow: parentRow) as? FolderOutlineItem else { throw failure("Parent folder missing") }
        outline.collapseItem(parent)
        try await settle(host)
        store.append(name: "background.txt", parent: child, size: 1, mtime: 0, isDir: false, volID: 1)
        store.append(name: "NewChild", parent: parent.record.id, size: 0, mtime: 0, isDir: true, volID: 1)
        index.publish(store)
        guard let hiddenSnapshot = await index.folderSnapshot() else { throw failure("Hidden branch snapshot missing") }
        host.rootView = root(hiddenSnapshot, selection: deepSelection)
        try await settle(host)
        try require(!outline.isItemExpanded(parent), "Background refresh reopened a collapsed selected branch")
        outline.expandItem(parent)
        try await settle(host)
        try require((0..<outline.numberOfRows).contains {
            (outline.item(atRow: $0) as? FolderOutlineItem)?.record.path == "/Folder20/NewChild"
        }, "Opening a collapsed branch omitted a newly indexed folder")
        let restoredPaths = outline.selectedRowIndexes.compactMap {
            (outline.item(atRow: $0) as? FolderOutlineItem)?.record.path
        }
        try require(Set(restoredPaths) == ["/Folder20/Child", "/Folder21"], "Opening a collapsed branch lost its selected descendant highlight")
        try require(modelWrites == 0, "Expanding or refreshing a branch changed the search scope")
        // A visible hierarchy change still has to appear. An ID reused for a
        // different path must be resolved to the new item, never the old cache.
        var rebuilt = fixture(reordered: true)
        rebuilt.append(name: "AddedFolder", parent: 0, size: 0, mtime: 0, isDir: true, volID: 1)
        index.publish(rebuilt)
        guard let next = await index.folderSnapshot() else { throw failure("Rebuilt fixture snapshot missing") }
        host.rootView = root(next, selection: selection)
        try await settle(host)
        let selectedPaths = outline.selectedRowIndexes.compactMap {
            (outline.item(atRow: $0) as? FolderOutlineItem)?.record.path
        }
        try require(Set(selectedPaths) == ["/Folder20", "/Folder21"], "Reused IDs redirected folder selection")
        try require((0..<outline.numberOfRows).contains { row in
            (outline.item(atRow: row) as? FolderOutlineItem)?.record.path == "/AddedFolder"
        }, "A new visible folder was not refreshed")
        print("CHECK: file-only native refresh failures=\(failures.count)")
        return failures
    }

    private static func fixture(reordered: Bool = false) -> FileStore {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        let offsets = reordered ? Array((0..<50).reversed()) : Array(0..<50)
        for offset in offsets {
            let folder = store.append(name: String(format: "Folder%02d", offset), parent: root,
                size: 0, mtime: 0, isDir: true, volID: 1)
            store.append(name: "item.txt", parent: folder, size: 1, mtime: 0, isDir: false, volID: 1)
        }
        return store
    }

    @MainActor private static func waitForReads(_ count: Int, sequence: FolderSnapshotSequence) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await sequence.reads < count {
            try require(ContinuousClock.now < deadline, "Snapshot fixture read timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(40))
    }
    @MainActor private static func settle(_ view: NSView) async throws {
        try await Task.sleep(for: .milliseconds(80))
        view.layoutSubtreeIfNeeded()
    }
    @MainActor private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            try require(ContinuousClock.now < deadline, "Sidebar refresh timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view]+view.subviews.flatMap { descendants($0) }
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }
    private static func failure(_ message: String) -> Error {
        NSError(domain: "FolderSidebarRefreshTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
