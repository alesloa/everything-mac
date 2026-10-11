import AppKit
import IndexCore

@main struct WindowIsolation {
    @MainActor private static func check(_ condition: @autoclosure () -> Bool,
                                        _ message: String = "Window state assertion", line: UInt = #line) {
        guard condition() else { print("FAIL at line \(line): \(message)"); exit(1) }
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let suite = "window-isolation-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: temporary)
        }
        let index = IndexActor(rules: .defaults, preferencesSuiteName: suite,
            cacheURL: temporary.appendingPathComponent("index.idx"), diskScanner: { _, _, _ in
                var store = FileStore()
                let root = store.append(name: "/", parent: FileStore.noParent, size: 0,
                                        mtime: 0, isDir: true, volID: 1)
                store.append(name: "first.txt", parent: root, size: 1, mtime: 1, isDir: false, volID: 1)
                store.append(name: "second.txt", parent: root, size: 2, mtime: 2, isDir: false, volID: 1)
                return store
            })
        let completed = await index.rescanAll()
        check(completed)
        let background = AppModel(index: index, preferences: preferences)
        let first = AppModel(index: index, preferences: preferences,
            workspace: SearchWorkspaceController(library: background.workspace.library))
        let second = AppModel(index: index, preferences: preferences,
            workspace: SearchWorkspaceController(library: background.workspace.library))
        first.prepareWindow(with: background)
        second.prepareWindow(with: background)
        first.restoreWorkspace(); second.restoreWorkspace()
        first.fuzzy = false; second.fuzzy = false
        first.query = "first"; second.query = "second"
        await first.runSearch(); await second.runSearch()
        check(first.results.map(\.name) == ["first.txt"])
        check(first.totalMatches == 1 && first.resultSnapshotID != nil)
        check(second.results.map(\.name) == ["second.txt"])
        first.caseSensitive = true; first.sortKey = .size
        check(second.query == "second" && !second.caseSensitive && second.sortKey != .size,
                     "A window changed another window's search options")

        background.rules.names = ["changed-rules"]
        background.shares = []
        background.total = index.totalCount
        background.scanning = true
        check(first.scanning && second.scanning)
        check(first.rules.names == ["changed-rules"] && second.total == 3)
        background.scanning = false
        background.indexRevision &+= 1
        try await Task.sleep(for: .milliseconds(100))
        check(first.results.map(\.name) == ["first.txt"] && second.results.map(\.name) == ["second.txt"])
        first.query = "first"
        let saved = try first.saveCurrentSearch(name: "First files", macroName: "firstfiles")
        check(second.workspace.library.archive.savedSearches.contains { $0.id == saved.id })
        first.query = "macro:firstfiles"
        await first.runSearch()
        check(first.searchError == nil && first.results.map(\.name) == ["first.txt"])
        first.query = "macro:missing"
        await first.runSearch()
        check(first.searchError != nil && first.results.isEmpty, "Invalid macros widened the query")
        first.query = "first"; first.searchError = nil
        first.workspaceStateChanged()
        let originalTab = first.workspace.window.selectedTabID
        first.newSearchTab()
        first.query = "second"; first.workspaceStateChanged()
        first.selectSearchTab(originalTab)
        await first.runSearch()
        check(first.query == "first", "Tab restored query \(first.query)")
        // Tab selection enqueues a search; await its accepted publication rather
        // than the separately awaited worker which may have been superseded.
        for _ in 0..<100 where first.results.map(\.name) != ["first.txt"] {
            try await Task.sleep(for: .milliseconds(10))
        }
        check(first.results.map(\.name) == ["first.txt"], "Restored results \(first.results.map(\.name))")
        check(second.query == "second" && second.workspace.window.tabs.count == 1)
        first.setFolderScope(FolderScope(path: "/"))
        first.indexedFolderTotals = true
        first.folderSidebarVisible = true
        first.persistWorkspace(); second.persistWorkspace()
        let restored = WorkspaceLibrary(preferences: preferences)
        check(restored.archive.windows.count == 2)
        check(restored.archive.windows.contains { $0.tabs.count == 2 })
        check(restored.archive.windows.contains {
            $0.selectedTab.state.folderScopePath == "/" && $0.selectedTab.state.indexedFolderTotals == true
        })
        print("PASS: windows keep independent searches and receive shared index updates")
    }
}
