import Foundation

/// Source: initial options below are explicit app defaults, then replaced by owner-entered query/options; no result IDs are saved.
public struct SearchWorkspaceState: Codable, Equatable, Sendable {
    public var query = ""
    public var matchPath = false
    public var caseSensitive = false
    public var wholeWord = false
    public var fuzzy = false
    public var regex = false
    public var diacriticInsensitive = false
    public var matchPrefix = false
    public var matchSuffix = false
    public var ignorePunctuation = false
    public var ignoreWhitespace = false
    public var searchFilter: SearchFilter = .all
    // Optional so older saved tabs, history and bookmarks retain their single filter.
    public var filters: SearchFilters?
    public var customFilterID: UUID?
    public var sortKey = "name"
    public var ascending = true
    public var resultLimit = 5000
    public var previewVisible = false
    public var thumbnailView = false
    // Source: these optional view/scope fields preserve older workspace archives;
    // paths are owner-selected indexed folders, and absent flags use app defaults.
    public var folderScopePath: String?
    // Source: owner-selected included and excluded indexed folders. Only paths
    // are persisted; FileStore IDs may change after rescanning or compaction.
    public var folderScopePaths: [String]?
    public var excludedFolderScopePaths: [String]?
    public var folderSidebarVisible: Bool?
    public var indexedFolderTotals: Bool?

    public init(query: String = "") { self.query = query }

    public var effectiveFilters: SearchFilters {
        filters ?? SearchFilters(types: searchFilter == .all ? [] : [searchFilter])
    }

    public var effectiveFolderSearchScope: FolderSearchScope? {
        // An explicit new inclusion array supersedes the legacy location.
        // A legacy location may still be combined with new excluded paths.
        let included = folderScopePaths ?? folderScopePath.map { [$0] } ?? []
        let excluded = excludedFolderScopePaths ?? []
        guard !included.isEmpty || !excluded.isEmpty else { return nil }
        return FolderSearchScope(included: included.map { FolderScope(path: $0) },
                                 excluded: excluded.map { FolderScope(path: $0) })
    }

    public var searchQuery: Query {
        effectiveFilters.applying(to: Query(text: query, matchPath: matchPath,
            caseInsensitive: !caseSensitive, wholeWord: wholeWord, fuzzy: fuzzy,
            regex: regex, diacriticInsensitive: diacriticInsensitive,
            matchPrefix: matchPrefix, matchSuffix: matchSuffix,
            ignorePunctuation: ignorePunctuation, ignoreWhitespace: ignoreWhitespace))
    }

    public var hasSearch: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !effectiveFilters.isEmpty || customFilterID != nil || effectiveFolderSearchScope != nil
    }

    public mutating func normalize() {
        // Source: SearchSettingsView's accepted result-limit range and app sort definitions.
        resultLimit = min(100_000, max(100, resultLimit))
        if !["relevance", "name", "path", "size", "mtime", "kind"].contains(sortKey) { sortKey = "name" }
    }
}

public struct SavedSearch: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var state: SearchWorkspaceState
    public var macroName: String
    public var isCustomFilter: Bool

    public init(id: UUID = UUID(), name: String, state: SearchWorkspaceState,
                macroName: String = "", isCustomFilter: Bool = false) {
        self.id = id; self.name = name; self.state = state
        self.macroName = macroName; self.isCustomFilter = isCustomFilter
    }
}

public struct SearchHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var state: SearchWorkspaceState
    public var completedAt: Date

    public init(id: UUID = UUID(), state: SearchWorkspaceState, completedAt: Date = Date()) {
        self.id = id; self.state = state; self.completedAt = completedAt
    }
}

public struct SearchHistoryPolicy: Codable, Equatable, Sendable {
    // Source: these are this application's explicit history defaults and limits.
    public var enabled = true
    public var maximumEntries = 200
    public var retentionDays = 30

    public init(enabled: Bool = true, maximumEntries: Int = 200, retentionDays: Int = 30) {
        self.enabled = enabled; self.maximumEntries = maximumEntries; self.retentionDays = retentionDays
    }

    public mutating func normalize() {
        maximumEntries = min(10_000, max(1, maximumEntries))
        retentionDays = min(3650, max(1, retentionDays))
    }
}

public struct SearchTabState: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var state: SearchWorkspaceState
    public var navigation: [SearchHistoryEntry]
    public var navigationIndex: Int
    // Source: this application's explicit per-tab navigation limit.
    public static let maximumNavigationEntries = 200

    public init(id: UUID = UUID(), state: SearchWorkspaceState = SearchWorkspaceState()) {
        self.id = id; self.state = state; self.navigation = []; self.navigationIndex = -1
    }

    public var canGoBack: Bool { navigationIndex > 0 }
    public var canGoForward: Bool { navigationIndex >= 0 && navigationIndex < navigation.count - 1 }

    public mutating func record(_ state: SearchWorkspaceState, at date: Date = Date()) {
        self.state = state
        guard state.hasSearch else { return }
        if navigation.indices.contains(navigationIndex), navigation[navigationIndex].state == state { return }
        navigation = Array(navigation.prefix(max(0, navigationIndex + 1)))
        navigation.append(SearchHistoryEntry(state: state, completedAt: date))
        if navigation.count > Self.maximumNavigationEntries {
            navigation.removeFirst(navigation.count - Self.maximumNavigationEntries)
        }
        navigationIndex = navigation.count - 1
    }

    @discardableResult public mutating func goBack() -> SearchWorkspaceState? {
        guard canGoBack else { return nil }
        navigationIndex -= 1; state = navigation[navigationIndex].state; return state
    }

    @discardableResult public mutating func goForward() -> SearchWorkspaceState? {
        guard canGoForward else { return nil }
        navigationIndex += 1; state = navigation[navigationIndex].state; return state
    }

    public mutating func clearNavigation() { navigation = []; navigationIndex = -1 }

    public mutating func pruneNavigation(after cutoff: Date, maximumEntries: Int) {
        let currentID = navigation.indices.contains(navigationIndex) ? navigation[navigationIndex].id : nil
        navigation = Array(navigation.filter { $0.completedAt >= cutoff }.suffix(maximumEntries))
        navigationIndex = currentID.flatMap { id in navigation.firstIndex { $0.id == id } } ?? -1
    }

    public mutating func normalize() {
        state.normalize()
        let dropped = max(0, navigation.count - Self.maximumNavigationEntries)
        navigation = Array(navigation.suffix(Self.maximumNavigationEntries))
        for i in navigation.indices { navigation[i].state.normalize() }
        navigationIndex = navigation.isEmpty || navigationIndex < 0 ? -1 : min(max(0, navigationIndex - dropped), navigation.count - 1)
    }
}

public struct SearchWindowState: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var tabs: [SearchTabState]
    public var selectedTabID: UUID
    // Source: this application's explicit tab limit bounds restored/persisted sessions.
    public static let maximumTabs = 64

    public init(id: UUID = UUID(), state: SearchWorkspaceState = SearchWorkspaceState()) {
        let tab = SearchTabState(state: state)
        self.id = id; self.tabs = [tab]; self.selectedTabID = tab.id
    }

    public var selectedTab: SearchTabState { tabs.first { $0.id == selectedTabID } ?? tabs[0] }

    public mutating func update(_ state: SearchWorkspaceState, record: Bool = false) {
        guard let i = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        if record { tabs[i].record(state) } else { tabs[i].state = state }
    }

    @discardableResult public mutating func addTab(state: SearchWorkspaceState = SearchWorkspaceState()) -> UUID? {
        guard tabs.count < Self.maximumTabs else { return nil }
        let tab = SearchTabState(state: state); tabs.append(tab); selectedTabID = tab.id
        return tab.id
    }

    public mutating func closeTab(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: i)
        if tabs.isEmpty { let tab = SearchTabState(); tabs = [tab]; selectedTabID = tab.id }
        else if selectedTabID == id { selectedTabID = tabs[min(i, tabs.count - 1)].id }
    }

    public mutating func normalize() {
        var ids: Set<UUID> = []
        tabs = Array(tabs.filter { ids.insert($0.id).inserted }.prefix(Self.maximumTabs))
        if tabs.isEmpty { tabs = [SearchTabState()] }
        for i in tabs.indices { tabs[i].normalize() }
        if !tabs.contains(where: { $0.id == selectedTabID }) { selectedTabID = tabs[0].id }
    }
}

public struct SearchWorkspaceArchive: Codable, Equatable, Sendable {
    public var version = 1
    public var savedSearches: [SavedSearch] = []
    public var history: [SearchHistoryEntry] = []
    public var historyPolicy = SearchHistoryPolicy()
    public var restoreSession = true
    public var windows: [SearchWindowState] = []

    public init() {}

    public mutating func record(_ state: SearchWorkspaceState, at date: Date = Date()) {
        pruneHistory(at: date)
        guard historyPolicy.enabled, state.hasSearch else { return }
        // Moving an existing search to the front avoids unbounded repeated refresh entries.
        history.removeAll { $0.state == state }
        history.insert(SearchHistoryEntry(state: state, completedAt: date), at: 0)
        pruneHistory(at: date)
    }

    public mutating func pruneHistory(at date: Date = Date()) {
        historyPolicy.normalize()
        if !historyPolicy.enabled { clearHistory(); return }
        let cutoff = date.addingTimeInterval(-Double(historyPolicy.retentionDays) * 86_400)
        history = Array(history.filter { $0.completedAt >= cutoff }.sorted { $0.completedAt > $1.completedAt }
            .prefix(historyPolicy.maximumEntries))
        for wi in windows.indices {
            for ti in windows[wi].tabs.indices {
                windows[wi].tabs[ti].pruneNavigation(after: cutoff, maximumEntries: historyPolicy.maximumEntries)
            }
        }
    }

    public mutating func clearHistory() {
        history = []
        for wi in windows.indices {
            for ti in windows[wi].tabs.indices { windows[wi].tabs[ti].clearNavigation() }
        }
    }

    public mutating func normalize(at date: Date = Date()) {
        pruneHistory(at: date)
        var windowIDs: Set<UUID> = [], bookmarkIDs: Set<UUID> = []
        windows = windows.filter { windowIDs.insert($0.id).inserted }
        savedSearches = savedSearches.filter { bookmarkIDs.insert($0.id).inserted }
        for i in windows.indices { windows[i].normalize() }
        for i in savedSearches.indices { savedSearches[i].state.normalize() }
    }
}
