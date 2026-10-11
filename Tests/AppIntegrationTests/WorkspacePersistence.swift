import Foundation
import Combine
import IndexCore

@main
struct WorkspacePersistence {
    @MainActor static func main() async throws {
        try verifyLiteralSearchMigration()
        let suite = "workspace-tests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let library = WorkspaceLibrary(preferences: preferences)
        let background = SearchWorkspaceController(library: library)
        precondition(background.windowID == nil)
        precondition(library.archive.windows.isEmpty)
        let first = SearchWorkspaceController(library: library)
        let second = SearchWorkspaceController(library: library)
        first.activate(defaultState: SearchWorkspaceState(query: "first"))
        second.activate(defaultState: SearchWorkspaceState(query: "second"))
        precondition(first.windowID != second.windowID)
        first.recordNow(SearchWorkspaceState(query: "first"))
        first.recordNow(SearchWorkspaceState(query: "changed"))
        precondition(first.back()?.query == "first")
        precondition(first.forward()?.query == "changed")
        let firstTab = first.window.selectedTabID
        precondition(first.newTab(state: SearchWorkspaceState(query: "new tab")) != nil)
        let newTab = first.window.selectedTabID
        precondition(first.selectTab(firstTab)?.query == "changed")
        precondition(first.selectTab(newTab)?.query == "new tab")
        precondition(second.window.selectedTab.state.query == "second")
        var observedChanges = 0
        let observation = second.objectWillChange.sink { observedChanges += 1 }
        try library.saveSearch(SavedSearch(name: "Saved first", state: first.window.selectedTab.state, macroName: "mine"))
        precondition(observedChanges > 0)
        precondition(second.library.archive.savedSearches.count == 1)
        withExtendedLifetime(observation) {}
        library.flush()
        let reloaded = WorkspaceLibrary(preferences: preferences)
        precondition(reloaded.savedWindowIDs.count == 2)
        let restoredFirst = SearchWorkspaceController(library: reloaded, windowID: first.windowID!.uuidString)
        let restoredSecond = SearchWorkspaceController(library: reloaded, windowID: second.windowID!.uuidString)
        precondition(restoredFirst.activate(defaultState: SearchWorkspaceState()).query == "new tab")
        precondition(restoredFirst.window.tabs.count == 2)
        precondition(restoredSecond.activate(defaultState: SearchWorkspaceState()).query == "second")
        precondition(reloaded.unclaimedWindowIDs.isEmpty)
        reloaded.clearHistory()
        precondition(restoredFirst.window.tabs.allSatisfy { $0.navigation.isEmpty })
        precondition(reloaded.archive.history.isEmpty)
        restoredFirst.stage(SearchWorkspaceState(query: "partial"))
        restoredFirst.recordCompleted(SearchWorkspaceState(query: "partial"))
        restoredFirst.stage(SearchWorkspaceState(query: "completed"))
        restoredFirst.recordCompleted(SearchWorkspaceState(query: "completed"))
        try await Task.sleep(for: .milliseconds(1150))
        precondition(reloaded.archive.history.map(\.state.query) == ["completed"])
        restoredFirst.stage(SearchWorkspaceState(query: "pending"))
        restoredFirst.recordCompleted(SearchWorkspaceState(query: "pending"))
        reloaded.clearHistory()
        try await Task.sleep(for: .milliseconds(1150))
        precondition(reloaded.archive.history.isEmpty)
        reloaded.setRestoreSession(false)
        let disabledRestoration = WorkspaceLibrary(preferences: preferences)
        precondition(disabledRestoration.savedWindowIDs.isEmpty)
        precondition(disabledRestoration.archive.savedSearches.count == 1)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("workspaces.json")
        let unreadable = Data("broken workspace".utf8)
        try unreadable.write(to: url)
        let corruptLibrary = WorkspaceLibrary(preferences: preferences, storageURL: url)
        precondition(corruptLibrary.storageError != nil)
        let untouched = try Data(contentsOf: url)
        precondition(untouched == unreadable)
        corruptLibrary.flush()
        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("workspaces.json.unreadable-") }
        precondition(backups.count == 1)
        let preserved = try Data(contentsOf: backups[0])
        let recovered = try SearchWorkspaceStore(url: url).load()
        precondition(preserved == unreadable)
        precondition(recovered.windows.isEmpty)
        print("PASS: independent tabs/windows, shared saves, isolated prefs, restoration and debounced history")
    }

    @MainActor private static func verifyLiteralSearchMigration() throws {
        let suite = "literal-default-tests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspaces.json")
        var legacy = SearchWorkspaceState(query: "expo")
        legacy.fuzzy = true; legacy.sortKey = "size"; legacy.caseSensitive = true
        legacy.filters = SearchFilters(types: [.files], over: SearchSizeLimit(amount: "500"))
        var window = SearchWindowState(state: legacy)
        window.update(legacy, record: true)
        _ = window.addTab(state: legacy)
        var archive = SearchWorkspaceArchive()
        archive.windows = [window]
        archive.savedSearches = [SavedSearch(name: "Saved fuzzy", state: legacy)]
        archive.record(legacy)
        try SearchWorkspaceStore(url: url).save(archive)
        preferences.set(true, forKey: "pref.fuzzy")
        let library = WorkspaceLibrary(preferences: preferences, storageURL: url)
        precondition(library.archive.windows.flatMap(\.tabs).allSatisfy { !$0.state.fuzzy })
        precondition(library.archive.windows[0].selectedTab.state.query == "expo")
        precondition(library.archive.windows[0].selectedTab.state.effectiveFilters == legacy.effectiveFilters)
        precondition(library.archive.windows[0].selectedTab.state.sortKey == "size")
        precondition(library.archive.windows[0].selectedTab.state.caseSensitive)
        precondition(library.archive.savedSearches[0].state.fuzzy && library.archive.history[0].state.fuzzy)
        precondition(library.archive.windows[0].tabs[0].navigation[0].state.fuzzy)
        precondition(!preferences.bool(forKey: "pref.fuzzy"))
        let controller = SearchWorkspaceController(library: library, windowID: window.id.uuidString)
        var optedIn = controller.activate(defaultState: SearchWorkspaceState())
        optedIn.fuzzy = true; controller.stage(optedIn)
        preferences.set(true, forKey: "pref.fuzzy"); library.flush()
        let reloaded = WorkspaceLibrary(preferences: preferences, storageURL: url)
        precondition(reloaded.archive.windows[0].selectedTab.state.fuzzy)
        precondition(preferences.bool(forKey: "pref.fuzzy"))

        preferences.removeObject(forKey: "pref.literalSearchDefault.v1")
        let beforeFailedSave = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let unwritable = WorkspaceLibrary(preferences: preferences, storageURL: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let afterFailedSave = try Data(contentsOf: url)
        precondition(unwritable.storageError != nil && beforeFailedSave == afterFailedSave)
        precondition(!preferences.bool(forKey: "pref.literalSearchDefault.v1"))
        unwritable.flush()
        precondition(unwritable.storageError == nil && preferences.bool(forKey: "pref.literalSearchDefault.v1"))

        preferences.removeObject(forKey: "pref.literalSearchDefault.v1")
        let broken = Data("broken archive".utf8)
        try broken.write(to: url)
        let corrupt = WorkspaceLibrary(preferences: preferences, storageURL: url)
        let untouched = try Data(contentsOf: url)
        precondition(corrupt.storageError != nil && untouched == broken)
        precondition(!preferences.bool(forKey: "pref.literalSearchDefault.v1"))
        corrupt.flush()
        precondition(corrupt.storageError == nil && preferences.bool(forKey: "pref.literalSearchDefault.v1"))
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("workspaces.json.unreadable-") }
        precondition(backups.count == 1)
        let preserved = try Data(contentsOf: backups[0])
        precondition(preserved == broken)
        print("PASS: literal defaults migrate restored tabs once and preserve saved searches, history, opt-in and recovery")
    }
}
