import AppKit
import Darwin
import IndexCore

@main struct MultiFolderWorkspaceTools {
    @MainActor static func main() async {
        do {
            _ = NSApplication.shared
            try await verify()
            print("PASS: multi-folder tabs, windows, collapsed restoration, saved searches, exports, content and duplicates")
        } catch {
            print("FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }

    @MainActor private static func verify() async throws {
        let suite = "multi-folder-workspace-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        // Match the existing content/duplicate fixtures: these readers refuse
        // symlink ancestors, including macOS's /var → /private/var alias.
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw Failure(message: "Temporary fixture path could not be resolved")
        }
        let directory = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent(suite)
        free(resolved)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let fixture = try makeFixture(directory)
        let index = IndexActor(rules: .defaults, preferencesSuiteName: suite,
            cacheURL: directory.appendingPathComponent("index.idx"), diskScanner: { _, _, _ in fixture.store })
        try require(await index.rescanAll(), "Fixture did not publish")
        let storageURL = directory.appendingPathComponent("workspaces.json")
        let library = WorkspaceLibrary(preferences: preferences, storageURL: storageURL)
        let first = AppModel(index: index, preferences: preferences,
            workspace: SearchWorkspaceController(library: library))
        let second = AppModel(index: index, preferences: preferences,
            workspace: SearchWorkspaceController(library: library))
        first.restoreWorkspace(); second.restoreWorkspace()
        first.query = ".txt"; second.query = ".txt"
        let selection = FolderSearchScope(included: [FolderScope(id: fixture.usersID, path: fixture.users),
            FolderScope(id: fixture.projectsID, path: fixture.projects)],
            excluded: [FolderScope(id: fixture.omitID, path: fixture.omit)])
        first.setFolderSearchScope(selection)
        second.setFolderScope(FolderScope(path: fixture.volumes))
        try await waitUntil { first.totalMatches == 2 && second.totalMatches == 1 }
        try require(first.folderScope == nil && first.folderSearchScope == selection,
                    "Multi-folder restriction was reduced to a single folder")
        try require(Set(first.results.map(\.path)) == Set(fixture.expected), "Included folders or exclusion were lost")
        first.setFolderSidebarVisible(false)
        let saved = try first.saveCurrentSearch(name: "Local folders")
        first.persistWorkspace(); second.persistWorkspace()
        let firstWindow = first.workspace.windowID!.uuidString
        let firstTab = first.workspace.window.selectedTabID
        first.newSearchTab()
        first.query = ".txt"
        first.setFolderSearchScope(FolderSearchScope(excluded: [FolderScope(path: fixture.volumes)]))
        try await waitUntil { first.totalMatches == 4 }
        first.selectSearchTab(firstTab)
        try await waitUntil { first.totalMatches == 2 }
        try require(first.folderSearchScope?.included.map(\.path) == [fixture.users, fixture.projects]
            && !first.folderSidebarVisible, "Tab switching lost a collapsed multi-folder selection")
        try require(second.folderScope?.path == fixture.volumes && second.totalMatches == 1,
                    "One window changed another window's folder restriction")
        first.persistWorkspace()
        let reloaded = WorkspaceLibrary(preferences: preferences, storageURL: storageURL)
        let restored = AppModel(index: index, preferences: preferences,
            workspace: SearchWorkspaceController(library: reloaded, windowID: firstWindow))
        restored.restoreWorkspace(); await restored.runSearch()
        try require(!restored.folderSidebarVisible && Set(restored.results.map(\.path)) == Set(fixture.expected),
                    "Restart widened a collapsed multi-folder search")
        try require(restored.folderSearchScope?.included.allSatisfy { $0.id == nil } == true
            && restored.folderSearchScope?.excluded.allSatisfy { $0.id == nil } == true,
                    "Workspace persisted FileStore IDs")
        restored.setFolderSearchScope(nil)
        try await waitUntil { restored.totalMatches == 5 }
        restored.openSavedSearch(saved)
        try await waitUntil { restored.totalMatches == 2 }
        try require(!restored.folderSidebarVisible, "Saved search did not retain collapsed visibility")
        restored.setFolderSearchScope(FolderSearchScope(included: [FolderScope(path: fixture.users)],
            excluded: [FolderScope(path: fixture.omit)]), revealSidebar: false)
        try await waitUntil { restored.totalMatches == 1 }
        try require(!restored.folderSidebarVisible, "Removing a collapsed scope entry forced the sidebar open")
        var legacy = SearchWorkspaceState(query: ".txt")
        legacy.folderScopePath = fixture.projects
        restored.applyWorkspace(legacy)
        try await waitUntil { restored.totalMatches == 1 }
        try require(restored.folderScope?.path == fixture.projects && restored.folderSidebarVisible,
                    "Older single-folder saved searches failed to restore")
        restored.openSavedSearch(saved)
        try await waitUntil { restored.totalMatches == 2 }
        let customFilter = try restored.saveCurrentSearch(name: "Text filter", isCustomFilter: true)
        restored.applySavedFilter(customFilter.id)
        try await waitUntil { restored.totalMatches == 2 }
        try require(restored.workspaceSnapshot.customFilterID == customFilter.id
            && restored.folderSearchScope?.excluded.map(\.path) == [fixture.omit],
                    "Custom filter normalization lost the full location selection")
        try await verifyTools(model: restored, fixture: fixture, directory: directory)
        restored.setFolderSearchScope(FolderSearchScope())
        try await waitUntil { restored.totalMatches == 5 }
        try require(restored.folderSearchScope == nil, "Empty explicit selection did not normalize to all folders")
    }

    @MainActor private static func verifyTools(model: AppModel, fixture: Fixture, directory: URL) async throws {
        let query = try model.resolvedWorkspaceQuery()
        let export = NativeResultsExportView(index: model.index.searchIndex, query: query, selected: [], shown: [],
            sort: .name, ascending: true, folderSelection: model.folderSearchScope)
        let output = directory.appendingPathComponent("matches.txt")
        let count = try export.matchingRequest.export(to: output, format: .txt)
        let lines = try String(contentsOf: output, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
        try require(count == 2 && Set(lines) == Set(fixture.expected), "Full export widened or truncated the selected folders")
        let duplicates = DuplicateFinderView(index: model.index.searchIndex, query: query, selectedPaths: [],
            folderSelection: model.folderSearchScope)
        guard let scope = duplicates.capturedQueryScope else { throw Failure(message: "Duplicate query scope was missing") }
        let duplicateReport = await DuplicateFinder().find(in: scope, method: .contents)
        try require(duplicateReport.inspectedFiles == 2
            && Set(duplicateReport.groups.flatMap(\.files).map(\.path)) == Set(fixture.expected),
                    "Duplicate query scope: inspected \(duplicateReport.inspectedFiles), hashed \(duplicateReport.hashedFiles), groups \(duplicateReport.groups.count), skipped \(duplicateReport.skipped.map { ($0.path, String(describing: $0.reason)) })")
        let content = ContentSearchModel(index: model.index.searchIndex, query: query, selectedPaths: [],
            folderSelection: model.folderSearchScope)
        content.literal = "needle"; content.useFilenameQuery = false; content.start()
        try await waitUntil { content.progress.finished }
        try require(content.progress.candidates == 2 && Set(content.progress.results.map(\.path)) == Set(fixture.expected),
                    "Content search broadened when filename filtering was disabled")
        let excludedOnly = FolderSearchScope(excluded: [FolderScope(path: fixture.volumes)])
        content.start()
        content.updateScope(query: query, folderSelection: excludedOnly)
        try require(!content.isRunning && content.progress.results.isEmpty, "Scope change retained stale content results")
        content.start()
        try await waitUntil { content.progress.finished }
        try require(content.progress.candidates == 4
            && content.progress.results.allSatisfy { !$0.path.hasPrefix(fixture.volumes + "/") },
                    "Exclusions-only content search searched the excluded drive")
        content.pickedFolderPath = fixture.projects; content.start()
        try await waitUntil { content.progress.finished }
        try require(content.progress.candidates == 1 && content.progress.results.first?.path == fixture.expected[1],
                    "Explicit content folder did not intersect the current folder selection")
        content.cancel()
    }

    private struct Fixture: Sendable {
        var store: FileStore
        let users: String, projects: String, omit: String, volumes: String
        let usersID: UInt32, projectsID: UInt32, omitID: UInt32
        let expected: [String]
    }

    private static func makeFixture(_ directory: URL) throws -> Fixture {
        var store = FileStore()
        let root = store.append(name: directory.path, parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        func folder(_ name: String, parent: UInt32) throws -> UInt32 {
            let id = store.append(name: name, parent: parent, size: 0, mtime: 0, isDir: true, volID: 1)
            try FileManager.default.createDirectory(atPath: store.path(of: id), withIntermediateDirectories: true)
            return id
        }
        func file(_ name: String, parent: UInt32) throws -> String {
            let data = Data("needle content\n".utf8)
            let id = store.append(name: name, parent: parent, size: UInt64(data.count), mtime: 0, isDir: false, volID: 1)
            let path = store.path(of: id)
            try data.write(to: URL(fileURLWithPath: path))
            return path
        }
        let users = try folder("Users", parent: root)
        let omit = try folder("omit", parent: users)
        let projects = try folder("Projects", parent: root)
        let volumes = try folder("Volumes", parent: root)
        let drive = try folder("Drive", parent: volumes)
        let sibling = try folder("Sibling", parent: root)
        let expected = [try file("alpha.txt", parent: users), try file("beta.txt", parent: projects)]
        _ = try file("omit.txt", parent: omit)
        _ = try file("volume.txt", parent: drive)
        _ = try file("outside.txt", parent: sibling)
        return Fixture(store: store, users: store.path(of: users), projects: store.path(of: projects),
            omit: store.path(of: omit), volumes: store.path(of: volumes), usersID: users, projectsID: projects,
            omitID: omit, expected: expected)
    }

    @MainActor private static func waitUntil(line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() >= deadline { throw Failure(message: "Timed out waiting for the current selection at line \(line)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
