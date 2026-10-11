import AppKit
import SwiftUI
import IndexCore

@main struct SearchBrowsingTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await run(); exit(EXIT_SUCCESS) }
            catch { print("FAIL: \(error.localizedDescription)"); exit(EXIT_FAILURE) }
        }
        app.run()
    }

    @MainActor private static func run() async throws {
        _ = NSApplication.shared
        let suite = "EverythingMac.SearchBrowsing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        var store = FileStore()
        let root = store.append(name: directory.path, parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        for number in 0..<12_001 {
            store.append(name: String(format: "file-%05d.txt", number), parent: root,
                         size: UInt64(number), mtime: Int64(number), isDir: false, volID: 1)
        }
        let fixtureStore = store
        let index = IndexActor(rules: .defaults, preferencesSuiteName: suite,
                              cacheURL: directory.appendingPathComponent("index.idx"),
                              diskScanner: { _, _, _ in fixtureStore }, networkMounts: { [] })
        try require(await index.rescanAll(), "Fixture index was not accepted")
        let model = AppModel(index: index, preferences: defaults)
        model.workspace.activate(defaultState: SearchWorkspaceState())
        model.query = "file"; model.fuzzy = false; model.sortKey = .name
        await model.runSearch()
        try require(model.results.count == 5000 && model.totalMatches == 12_001, "Native search did not prepare its first rows")
        let list = try requireValue(model.resultList, "Missing full result list")
        let parent = ResultsTable(rows: model.results, onSort: { _, _ in }, onSelect: { _ in }, onActivate: { _ in },
                                  onSelection: model.selectRecords, selectedRecords: model.actionRecords,
                                  query: model.currentQuery, resultList: list, onRowSelection: model.selectRows,
                                  onRowAction: model.performRows)
        let coordinator = ResultsTable.Coordinator(parent, columnDefaults: defaults)
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        table.allowsMultipleSelection = true
        coordinator.table = table; coordinator.installColumns(in: table)
        table.dataSource = coordinator; table.delegate = coordinator
        let scroll = NSScrollView(frame: table.frame); scroll.documentView = table
        coordinator.observe(scroll.contentView)
        coordinator.reload(parent)
        try require(table.numberOfRows == 12_001, "The native scrollbar cannot reach all matches")
        _ = coordinator.record(at: 12_000)
        try require(await list.prepareTail() && list.record(at: 12_000) != nil, "The last viewport waited for a complete sort")
        try require(await list.prepare(), "Deep-scroll order did not complete")
        await coordinator.orderingTask?.value
        let last = try requireValue(coordinator.record(at: 12_000), "Last result is unreachable")
        try require(last.name == "file-12000.txt", "Deep scrolling changed the sort order")
        table.scrollRowToVisible(12_000)
        table.selectRowIndexes(IndexSet(integer: 12_000), byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        try require(model.actionRecords == [last] && model.selected == last, "File actions lost a pick beyond the initial page")
        var updated = parent; updated.selectedRecords = model.actionRecords
        updated.selectedRows = model.rowSelection
        coordinator.reload(updated)
        await coordinator.selectionTask?.value
        try require(coordinator.selectedRecords() == [last], "A normal update cleared the deep selection")
        store.append(name: "file-12001.txt", parent: root, size: 12_001, mtime: 12_001, isDir: false, volID: 1)
        index.searchIndex.publish(store)
        await model.runSearch()
        var refreshed = parent
        refreshed.resultList = model.resultList; refreshed.rows = model.results
        refreshed.selectedRecords = model.actionRecords; refreshed.selectedRows = model.rowSelection
        coordinator.reload(refreshed)
        await coordinator.selectionTask?.value; await coordinator.orderingTask?.value
        try require(model.actionRecords == [last] && coordinator.selectedRecords() == [last],
                    "An index publication cleared the deep selection")
        model.refreshResultsFromIndex()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.resultList === refreshed.resultList, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(model.resultList !== refreshed.resultList && model.resultList?.isPrepared == true &&
                    model.resultList?.record(at: 12_001)?.name == "file-12001.txt",
                    "Background refresh replaced scrollable rows with an unprepared list")
        let cold = await index.searchIndex.searchReport(Query(text: "file"), sort: .name, limit: 5000, includeAllResults: true)
        refreshed.resultList = cold.resultList; refreshed.rows = cold.records
        refreshed.selectedRows = nil; refreshed.selectedRecords = []
        model.resultList = cold.resultList; model.rowSelection = nil
        coordinator.reload(refreshed)
        table.selectAll(nil)
        coordinator.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        try require(table.selectedRowIndexes.count == 12_002 && model.selectionCount == 12_002 && model.actionRecords.count <= 32,
                    "Select All was truncated or decoded the whole list on the main thread")
        refreshed.selectedRows = model.rowSelection; refreshed.selectedRecords = model.actionRecords
        coordinator.reload(refreshed)
        try require(table.selectedRowIndexes.count == 12_002, "Reload narrowed Select All")
        let fullSelection = try requireValue(model.rowSelection, "Missing full selected row ranges")
        let selectedFiles = await fullSelection.records()
        try require(selectedFiles.count == 12_002 && selectedFiles.last?.name == "file-12001.txt", "Explicit actions miss selected rows")
        let selectedExport = directory.appendingPathComponent("selected.txt")
        let exported = try CatalogIO.exportSelection(fullSelection, to: selectedExport, format: .txt)
        try require(exported == 12_002, "Selected export was truncated")
        try await thumbnailSelection(index: index, rows: cold.records)
        for row in 0..<1000 { _ = coordinator.record(at: row) }
        try require(coordinator.rowCache.count <= 512, "Decoded row cache grows with the entire list")
        let before = model.workspace.window.selectedTabID
        model.closeSearchTab()
        try require(model.workspace.window.selectedTabID == before, "Closing the last tab replaced it")
        model.setSearchFilter(.files)
        try require(model.searchFilter == .files, "Filter menu did not apply Files")
        model.newSearchTab()
        try require(model.workspace.window.tabs.count == 2, "New tab did not appear")
        model.closeSearchTab()
        try require(model.workspace.window.tabs.count == 1 && model.workspace.window.selectedTabID == before,
                    "Close tab did not remove the tab")
        let saved = try model.saveCurrentSearch(name: "Only text", isCustomFilter: true)
        model.applySavedFilter(saved.id)
        model.setSearchFilter(.all)
        try require(model.workspace.window.selectedTab.state.customFilterID == nil && model.searchFilter == .all,
                    "Everything left an invisible saved filter active")
        coordinator.stop()
        try await streamingScan(in: directory, suite: suite)
        print("PASS: all 12,001 rows scrollable, deep selections actionable, bounded row cache, intuitive tabs/filters, searchable scan batches and cancelled-scan recovery")
    }

    @MainActor private static func thumbnailSelection(index: IndexActor, rows: [FileRecord]) async throws {
        let report = await index.searchIndex.searchReport(Query(text: "file"), sort: .name, limit: 5000, includeAllResults: true)
        let list = try requireValue(report.resultList, "Missing thumbnail result list")
        var published: SearchRowSelection?, dispatched: SearchRowSelection?
        var activated: [FileRecord] = []
        let parent = ThumbnailResultsView(rows: rows, onSelection: { _ in }, onActivate: { activated.append($0) }, resultList: list,
            onRowSelection: { published = $0 },
            onRowAction: { selection, _ in dispatched = selection })
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 400),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: parent)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let collection = try requireValue(findCollection(window.contentView), "Native thumbnail collection did not render")
        let coordinator = try requireValue(collection.delegate as? ThumbnailResultsView.Coordinator, "Missing native grid coordinator")
        window.makeFirstResponder(collection)
        let layout = try requireValue(collection.collectionViewLayout as? ResultsGridLayout, "Missing virtual grid layout")
        let attributes = layout.layoutAttributesForElements(in: NSRect(x: 0, y: 0, width: 800, height: 400))
        try require(attributes.count < 32 && layout.layoutAttributesForItem(at: IndexPath(item: list.count - 1, section: 0)) != nil,
                    "Thumbnail geometry does not stay limited to the viewport")
        coordinator.selectAllRows()
        try require(published?.count == list.count && collection.selectionIndexPaths.count <= 512,
                    "Thumbnail Select All materialized or dropped offscreen rows")
        try await click(collection, item: 0, flags: .command)
        try await Task.sleep(for: .milliseconds(100))
        try require(published?.count == list.count - 1 && published?.rows.contains(list.count - 1) == true,
                    "Command-deselect lost offscreen thumbnail selections: \(published?.count ?? -1) of \(list.count)")
        try await click(collection, item: 0, flags: .command)
        try await Task.sleep(for: .milliseconds(100))
        try require(published?.count == list.count, "Command-select failed to preserve distant selections")
        collection.scrollToItems(at: [IndexPath(item: list.count - 1, section: 0)], scrollPosition: .bottom)
        try await Task.sleep(for: .milliseconds(200))
        try require(await list.prepare(), "Thumbnail deep ordering did not complete")
        try await Task.sleep(for: .milliseconds(100))
        try require(collection.item(at: IndexPath(item: list.count - 1, section: 0))?.textField?.stringValue == "file-12001.txt",
                    "Deep scrolling did not render the final thumbnail")
        try require(published?.count == list.count, "Ordering completion narrowed the thumbnail selection")
        for width in [347.0, 348.0] {
            window.setContentSize(NSSize(width: width, height: 400))
            try await Task.sleep(for: .milliseconds(50))
            collection.layoutSubtreeIfNeeded()
            collection.scrollToItems(at: [IndexPath(item: list.count - 1, section: 0)], scrollPosition: .bottom)
            try await Task.sleep(for: .milliseconds(50))
            try require(collection.item(at: IndexPath(item: list.count - 1, section: 0))?.view.frame.intersects(collection.visibleRect) == true,
                        "Column-count resize lost the final thumbnail")
        }
        coordinator.parent.selectedRows = SearchRowSelection(list: list, rows: IndexSet(integersIn: 0..<600))
        coordinator.refreshVisible()
        try require(collection.selectionIndexPaths.isEmpty, "Offscreen selection was displayed at the wrong rows")
        try require(coordinator.handleResultKey(.copy) && dispatched?.count == 600,
                    "Keyboard actions ignored offscreen selected thumbnails")
        let clicked = try requireValue(collection.indexPathsForVisibleItems().first {
            collection.item(at: $0).map { collection.visibleRect.contains($0.view.frame) } == true
        }, "No fully visible thumbnail to click")
        try await click(collection, item: clicked.item, flags: [])
        try await Task.sleep(for: .milliseconds(100))
        try require(published?.count == 1, "Ordinary click did not replace thumbnail selection: \(published?.count ?? -1), native \(collection.selectionIndexPaths.count), modifiers \(collection.selectionModifiers.rawValue)")
        try await click(collection, item: clicked.item, flags: [], clickCount: 2)
        try require(activated.count == 1 && activated.first == list.record(at: clicked.item), "Native double click did not activate exactly the clicked file")
        coordinator.stop()
    }

    @MainActor private static func findCollection(_ view: NSView?) -> ResultsKeyCollectionView? {
        if let collection = view as? ResultsKeyCollectionView { return collection }
        for child in view?.subviews ?? [] { if let found = findCollection(child) { return found } }
        return nil
    }

    @MainActor private static func click(_ collection: NSCollectionView, item: Int, flags: NSEvent.ModifierFlags, clickCount: Int = 1) async throws {
        let view = try requireValue(collection.item(at: IndexPath(item: item, section: 0))?.view, "Missing clicked thumbnail")
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let window = try requireValue(collection.window, "Thumbnail has no window")
        var events: [NSEvent] = []
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try requireValue(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1), "Cannot create native mouse event")
            events.append(event)
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(collection)
        NSApp.activate(ignoringOtherApps: true)
        try await waitUntil { NSApp.isActive && window.isKeyWindow }
        NSApp.sendEvent(events[0])
        NSApp.sendEvent(events[1])
    }

    @MainActor private static func streamingScan(in directory: URL, suite: String) async throws {
        let fixture = StreamingFixture(root: directory.path)
        let index = IndexActor(rules: .defaults, preferencesSuiteName: suite,
                              cacheURL: directory.appendingPathComponent("stream.idx"),
                              streamingDiskScanner: { _, cancelled, progress, snapshot in
                                  fixture.scan(cancelled: cancelled, progress: progress, snapshot: snapshot)
                              }, networkMounts: { [] })
        let scan = Task { await index.rescanAll() }
        try await waitUntil { index.totalCount == 2 }
        let report = await index.searchIndex.searchReport(Query(text: "first"))
        try require(report.records.map(\.name) == ["first.txt"], "Discovered files are not searchable before the scan ends")
        try require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("stream.idx").path),
                    "A partial scan was written to the cache")
        scan.cancel()
        fixture.release()
        try require(!(await scan.value), "Cancelled scan was accepted")
        try require(index.totalCount == 0, "Cancelled scan left a partial replacement published")
        try require(index.activitySnapshot().indexedCount == 0, "Cancelled scan left discarded activity totals")
        let next = Task { await index.rescanAll() }
        fixture.release()
        try require(await next.value, "Subsequent scan did not finish")
        let final = await index.searchIndex.searchReport(Query(text: ""))
        try require(final.totalMatches == 3, "Completed scan lost discovered files")
        let supersededFixture = StreamingFixture(root: directory.path)
        let superseded = IndexActor(rules: .defaults, preferencesSuiteName: suite,
            streamingDiskScanner: { _, cancelled, progress, snapshot in
                supersededFixture.scan(cancelled: cancelled, progress: progress, snapshot: snapshot)
            }, networkMounts: { [] })
        let old = Task { await superseded.rescanAll() }
        try await waitUntil { superseded.totalCount == 2 }
        supersededFixture.failNext()
        try require(!(await superseded.rescanAll()), "Unreadable replacement was accepted")
        supersededFixture.release()
        try require(!(await old.value), "Superseded scan was accepted")
        try require(superseded.totalCount == 0 && superseded.activitySnapshot().indexedCount == 0,
                    "A failed successor left its predecessor's discarded files published")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "SearchBrowsingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw NSError(domain: "SearchBrowsingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        return value
    }
    @MainActor private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try require(false, "Timed out waiting for a scan publication")
    }
}

private final class StreamingFixture: @unchecked Sendable {
    private let root: String
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var shouldFail = false
    init(root: String) { self.root = root }
    func release() { gate.signal() }
    func failNext() { lock.withLock { shouldFail = true } }
    func scan(cancelled: @Sendable () -> Bool, progress: @Sendable (Int) -> Void,
              snapshot: @Sendable (FileStore) -> Void) -> FileStore {
        if lock.withLock({ let fail = shouldFail; shouldFail = false; return fail }) { return FileStore() }
        var store = FileStore()
        let root = store.append(name: root, parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        store.append(name: "first.txt", parent: root, size: 1, mtime: 1, isDir: false, volID: 1)
        snapshot(store.storageSnapshot()); progress(store.count)
        _ = gate.wait(timeout: .now() + 5)
        if cancelled() { return FileStore() }
        store.append(name: "last.txt", parent: root, size: 2, mtime: 2, isDir: false, volID: 1)
        return store
    }
}
