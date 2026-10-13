import Foundation
import Testing
@testable import IndexCore

@Suite struct SearchWorkspaceTests {
    @Test func folderSelectionRoundTripsPathsAndRestoresLegacySingleFolder() throws {
        var legacy = SearchWorkspaceState()
        legacy.folderScopePath = "/Users"
        let legacyData = try JSONEncoder().encode(legacy)
        #expect(!String(decoding: legacyData, as: UTF8.self).contains("folderScopePaths"))
        #expect(try JSONDecoder().decode(SearchWorkspaceState.self, from: legacyData)
            .effectiveFolderSearchScope == FolderSearchScope(included: [FolderScope(path: "/Users")]))
        legacy.excludedFolderScopePaths = ["/Users/Cache"]
        #expect(legacy.effectiveFolderSearchScope == FolderSearchScope(included: [FolderScope(path: "/Users")],
            excluded: [FolderScope(path: "/Users/Cache")]))

        var selected = SearchWorkspaceState()
        selected.folderScopePaths = ["/Users", "/Projects"]
        selected.excludedFolderScopePaths = ["/Users/Cache", "/Volumes"]
        selected.folderSidebarVisible = false
        #expect(selected.hasSearch)
        var window = SearchWindowState(state: selected)
        window.update(selected, record: true)
        var archive = SearchWorkspaceArchive()
        archive.windows = [window]
        archive.savedSearches = [SavedSearch(name: "Local folders", state: selected)]
        archive.record(selected)
        let encoded = try SearchWorkspaceStore.encode(archive)
        let restored = try SearchWorkspaceStore.decode(encoded)
        #expect(restored == archive)
        let scope = restored.windows[0].selectedTab.state.effectiveFolderSearchScope
        #expect(scope?.included.map(\.path) == ["/Users", "/Projects"])
        #expect(scope?.excluded.map(\.path) == ["/Users/Cache", "/Volumes"])
        #expect(scope?.included.allSatisfy { $0.id == nil } == true)
        #expect(scope?.excluded.allSatisfy { $0.id == nil } == true)
        #expect(restored.windows[0].selectedTab.state.folderSidebarVisible == false)

        // Explicit new fields supersede a stale legacy path, including a cleared
        // selection and exclusions-only "all except" searches.
        selected.folderScopePath = "/stale"
        selected.folderScopePaths = []; selected.excludedFolderScopePaths = []
        #expect(selected.effectiveFolderSearchScope == nil && !selected.hasSearch)
        selected.excludedFolderScopePaths = ["/Volumes"]
        #expect(selected.hasSearch && selected.effectiveFolderSearchScope?.included.isEmpty == true)
    }

    @Test func plainSearchMatchesConsecutiveTextAndFuzzyRequiresOptIn() async {
        var store = FileStore()
        let root = store.append(name: "/fixture", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        for name in ["expo", "Expo.app", "export.swift", "e_x_p_o.txt", "index-position.txt", "photo.png"] {
            store.append(name: name, parent: root, size: 1, mtime: 0, isDir: false, volID: 1)
        }
        let index = SearchIndex(); index.publish(store)
        var state = SearchWorkspaceState(query: "expo")
        state.filters = SearchFilters(types: [.files])
        #expect(!state.fuzzy && state.sortKey == "name")
        let literal = Set(["expo", "Expo.app", "export.swift"])
        #expect(Set(await index.search(state.searchQuery).map(\.name)) == literal)
        state.fuzzy = true
        #expect(Set(await index.search(state.searchQuery).map(\.name)) == literal.union(["e_x_p_o.txt", "index-position.txt"]))
        state.fuzzy = false
        #expect(Set(await index.search(state.searchQuery).map(\.name)) == literal)
    }

    @Test func completeStateRoundTripsWithoutSavingResults() throws {
        var state = SearchWorkspaceState(query: "name:\"Résumé report\" size:>1KiB")
        state.matchPath = true; state.caseSensitive = true; state.wholeWord = true; state.fuzzy = false
        state.regex = true; state.diacriticInsensitive = true; state.matchPrefix = true; state.matchSuffix = true
        state.ignorePunctuation = true; state.ignoreWhitespace = true; state.searchFilter = .documents
        state.customFilterID = UUID(); state.sortKey = "mtime"; state.ascending = false; state.resultLimit = 4200
        state.previewVisible = true; state.thumbnailView = true
        var archive = SearchWorkspaceArchive()
        let saved = SavedSearch(name: "My report", state: state, macroName: "reports", isCustomFilter: true)
        archive.savedSearches = [saved]
        var window = SearchWindowState(state: state)
        window.update(state, record: true)
        archive.windows = [window]
        let date = Date()
        archive.record(state, at: date)
        let encoded = try SearchWorkspaceStore.encode(archive)
        #expect(try SearchWorkspaceStore.decode(encoded, at: date) == archive)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("selectedID"))
    }

    @Test func tabsAndWindowsKeepTheirOwnStateAndBranchNavigation() {
        let a = SearchWorkspaceState(query: "alpha"), b = SearchWorkspaceState(query: "beta")
        var first = SearchWindowState(state: a), second = SearchWindowState(state: b)
        first.update(a, record: true); first.update(b, record: true)
        let original = first.selectedTabID
        #expect(first.tabs[0].goBack() == a)
        first.tabs[0].record(SearchWorkspaceState(query: "gamma"))
        #expect(!first.tabs[0].canGoForward)
        #expect(first.tabs[0].navigation.map(\.state.query) == ["alpha", "gamma"])
        #expect(first.addTab(state: b) != nil)
        first.update(SearchWorkspaceState(query: "changed"))
        #expect(first.tabs.first { $0.id == original }?.state.query == "gamma")
        #expect(second.selectedTab.state == b)
        first.closeTab(first.selectedTabID)
        #expect(first.selectedTabID == original)
        second.closeTab(second.selectedTabID)
        #expect(second.tabs.count == 1)
        #expect(second.selectedTab.state.query.isEmpty)
    }

    @Test func historyRetainsRealCompletedSearchesAndClearRemovesNavigation() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var archive = SearchWorkspaceArchive()
        archive.historyPolicy = SearchHistoryPolicy(maximumEntries: 2, retentionDays: 2)
        archive.record(SearchWorkspaceState(query: "expired"), at: now.addingTimeInterval(-3 * 86_400))
        archive.record(SearchWorkspaceState(query: "one"), at: now.addingTimeInterval(-60))
        archive.record(SearchWorkspaceState(query: "two"), at: now.addingTimeInterval(-30))
        archive.record(SearchWorkspaceState(query: "three"), at: now)
        #expect(archive.history.map(\.state.query) == ["three", "two"])
        archive.record(SearchWorkspaceState(query: "two"), at: now.addingTimeInterval(1))
        #expect(archive.history.map(\.state.query) == ["two", "three"])
        #expect(archive.history[0].completedAt == now.addingTimeInterval(1))
        archive.record(SearchWorkspaceState(), at: now.addingTimeInterval(1))
        #expect(archive.history.count == 2)
        var window = SearchWindowState()
        window.update(SearchWorkspaceState(query: "one"), record: true)
        window.update(SearchWorkspaceState(query: "two"), record: true)
        archive.windows = [window]
        archive.clearHistory()
        #expect(archive.history.isEmpty)
        #expect(archive.windows[0].selectedTab.navigation.isEmpty)
        #expect(archive.windows[0].selectedTab.state.query == "two")
        archive.historyPolicy.enabled = false
        archive.record(SearchWorkspaceState(query: "disabled"), at: now)
        #expect(archive.history.isEmpty)
    }

    @Test func persistenceIsAtomicAndRejectsCorruptOrUnsupportedData() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SearchWorkspaceStore(url: dir.appendingPathComponent("nested/workspaces.json"))
        #expect(try store.load().windows.isEmpty)
        var archive = SearchWorkspaceArchive()
        archive.windows = [SearchWindowState(state: SearchWorkspaceState(query: "first"))]
        try store.save(archive)
        archive.windows[0].update(SearchWorkspaceState(query: "second"))
        try store.save(archive)
        #expect(try store.load() == archive)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path) == ["workspaces.json"])
        let original = try Data(contentsOf: store.url)
        try Data("broken".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try Data(contentsOf: store.url) == Data("broken".utf8))
        #expect(try SearchWorkspaceStore.decode(original) == archive)
        archive.version = 99
        #expect(throws: SearchWorkspaceStoreError.self) { try SearchWorkspaceStore.decode(SearchWorkspaceStore.encode(archive)) }
        #expect(throws: SearchWorkspaceStoreError.self) {
            try SearchWorkspaceStore.decode(Data(count: SearchWorkspaceStore.maximumFileBytes + 1))
        }
    }

    @Test func restoredStateNormalizesInvalidSelectionAndBoundsNavigation() throws {
        var window = SearchWindowState()
        window.selectedTabID = UUID()
        window.tabs[0].navigation = (0..<300).map { SearchHistoryEntry(state: SearchWorkspaceState(query: String($0))) }
        window.tabs[0].navigationIndex = 299
        window.tabs[0].state.resultLimit = -1
        window.tabs[0].state.sortKey = "unsupported"
        window.tabs.append(window.tabs[0])
        var archive = SearchWorkspaceArchive(); archive.windows = [window, window]
        let restored = try SearchWorkspaceStore.decode(SearchWorkspaceStore.encode(archive))
        #expect(restored.windows.count == 1)
        #expect(restored.windows[0].tabs.count == 1)
        #expect(restored.windows[0].selectedTab.navigation.count == 200)
        #expect(restored.windows[0].selectedTab.navigationIndex == 199)
        #expect(restored.windows[0].selectedTab.state.resultLimit == 100)
        #expect(restored.windows[0].selectedTab.state.sortKey == "name")
    }

    @Test func macrosExpandSavedQueriesWithGroupingAndPreserveQuotedLiterals() throws {
        let pdf = SavedSearch(name: "Documents", state: SearchWorkspaceState(query: "ext:pdf | ext:txt"), macroName: "docs")
        let nested = SavedSearch(name: "Reports", state: SearchWorkspaceState(query: "macro:docs report"), macroName: "reports")
        let macros = SearchMacroExpansion(savedSearches: [pdf, nested])
        let expanded = try macros.expand("macro:reports NOT draft")
        #expect(expanded == "((ext:pdf | ext:txt) report) NOT draft")
        #expect(Query(text: expanded).validationError == nil)
        #expect(try macros.expand("\"macro:docs\" \\macro:docs") == "\"macro:docs\" \\macro:docs")
        #expect(try macros.expand("macro:DOCS") == "(ext:pdf | ext:txt)")
        #expect(throws: SearchMacroError.unknown("missing")) { try macros.expand("macro:missing") }
        #expect(throws: SearchMacroError.invalidName("bad!")) { try macros.expand("macro:bad!") }
        let duplicate = SavedSearch(name: "Duplicate", state: SearchWorkspaceState(query: "other"), macroName: "docs")
        #expect(throws: SearchMacroError.duplicate("docs")) { try SearchMacroExpansion(savedSearches: [pdf, duplicate]).expand("macro:docs") }
    }

    @Test func recursiveAndExpansiveMacrosStopBeforeSearching() throws {
        let recursive = SavedSearch(name: "Loop", state: SearchWorkspaceState(query: "macro:loop"), macroName: "loop")
        #expect(throws: SearchMacroError.recursive("loop")) { try SearchMacroExpansion(savedSearches: [recursive]).expand("macro:loop") }
        let chain = (0..<18).map { n in SavedSearch(name: "\(n)", state: SearchWorkspaceState(query: "macro:q\(n + 1)"), macroName: "q\(n)") }
        #expect(throws: SearchMacroError.expansionLimit) { try SearchMacroExpansion(savedSearches: chain).expand("macro:q0") }
        let many = SavedSearch(name: "Many", state: SearchWorkspaceState(query: "name:x"), macroName: "many")
        #expect(throws: SearchMacroError.expansionLimit) {
            try SearchMacroExpansion(savedSearches: [many]).expand(String(repeating: "macro:many ", count: 257))
        }
    }

    @Test func savedCustomFiltersCombineWithRegexAndBuiltInFilters() throws {
        var filterState = SearchWorkspaceState(query: "report | summary")
        filterState.searchFilter = .documents
        let filter = SavedSearch(name: "Reports", state: filterState, isCustomFilter: true)
        var state = SearchWorkspaceState(query: "^annual")
        state.regex = true; state.customFilterID = filter.id
        let query = try SearchMacroExpansion(savedSearches: [filter]).resolve(state)
        #expect(!query.regex)
        #expect(query.validationError == nil)
        var store = FileStore()
        for name in ["annual report.pdf", "annual summary.txt", "annual report.mp3", "old report.pdf"] {
            store.append(name: name, parent: FileStore.noParent, size: 0, mtime: 0, isDir: false, volID: 1)
        }
        let matches = QueryEngine().search(query, in: store).map { store.name(of: $0) }
        #expect(Set(matches) == ["annual report.pdf", "annual summary.txt"])
        state.customFilterID = UUID()
        #expect(throws: SearchMacroError.missingFilter) { try SearchMacroExpansion(savedSearches: [filter]).resolve(state) }
    }

    @Test func retentionPrunesTabNavigationWithoutChangingCurrentSearch() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var window = SearchWindowState()
        window.tabs[0].record(SearchWorkspaceState(query: "old"), at: now.addingTimeInterval(-3 * 86_400))
        window.tabs[0].record(SearchWorkspaceState(query: "current"), at: now)
        var archive = SearchWorkspaceArchive()
        archive.historyPolicy = SearchHistoryPolicy(maximumEntries: 2, retentionDays: 1)
        archive.windows = [window]; archive.pruneHistory(at: now)
        #expect(archive.windows[0].selectedTab.navigation.map(\.state.query) == ["current"])
        #expect(!archive.windows[0].selectedTab.canGoBack)
        #expect(archive.windows[0].selectedTab.state.query == "current")
        archive.historyPolicy.enabled = false; archive.pruneHistory(at: now)
        #expect(archive.windows[0].selectedTab.navigation.isEmpty)
    }
}
