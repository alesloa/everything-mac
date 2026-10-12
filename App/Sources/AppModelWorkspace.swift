import Foundation
import IndexCore

@MainActor
extension AppModel {
    var workspaceSnapshot: SearchWorkspaceState {
        var state = SearchWorkspaceState(query: query)
        state.matchPath = matchPath; state.caseSensitive = caseSensitive; state.wholeWord = wholeWord
        state.fuzzy = fuzzy; state.regex = regex; state.diacriticInsensitive = diacriticInsensitive
        state.matchPrefix = matchPrefix; state.matchSuffix = matchSuffix
        state.ignorePunctuation = ignorePunctuation; state.ignoreWhitespace = ignoreWhitespace
        state.searchFilter = searchFilter; state.filters = searchFilters
        state.customFilterID = workspace.window.selectedTab.state.customFilterID
        state.sortKey = Self.sortKeyName(sortKey); state.ascending = ascending; state.resultLimit = resultLimit
        state.previewVisible = previewVisible; state.thumbnailView = thumbnailView
        state.folderScopePath = folderScope?.path
        state.folderSidebarVisible = folderSidebarVisible; state.indexedFolderTotals = indexedFolderTotals
        return state
    }

    func restoreWorkspace() {
        workspace.observeSavedSearches { [weak self] in Task { await self?.runSearch() } }
        applyWorkspace(workspace.activate(defaultState: workspaceSnapshot), search: false)
    }
    func workspaceStateChanged() { workspace.stage(workspaceSnapshot) }
    func recordCompletedWorkspaceSearch() { workspace.recordCompleted(workspaceSnapshot) }

    func applyWorkspace(_ state: SearchWorkspaceState, search: Bool = true) {
        query = state.query; matchPath = state.matchPath; caseSensitive = state.caseSensitive
        wholeWord = state.wholeWord; fuzzy = state.fuzzy; regex = state.regex
        diacriticInsensitive = state.diacriticInsensitive; matchPrefix = state.matchPrefix; matchSuffix = state.matchSuffix
        ignorePunctuation = state.ignorePunctuation; ignoreWhitespace = state.ignoreWhitespace
        searchFilters = state.effectiveFilters; sortKey = Self.sortKey(from: state.sortKey); ascending = state.ascending
        resultLimit = state.resultLimit; previewVisible = state.previewVisible; thumbnailView = state.thumbnailView
        folderScope = state.folderScopePath.map { FolderScope(path: $0) }
        // Source: the owner wants collapsing to retain the selected location.
        // Honor saved visibility; older scoped searches without it start expanded.
        folderSidebarVisible = state.folderSidebarVisible ?? (folderScope != nil)
        indexedFolderTotals = state.indexedFolderTotals ?? false
        indexedTotalsColumnOverride = state.indexedFolderTotals
        refreshFolderDetailsIfNeeded()
        resultList = nil
        rowSelection = nil; selectionGeneration &+= 1
        visibleResults = []
        resultOrdering = false
        selectedRecords = []; selectedID = nil; results = []
        totalMatches = nil; resultSnapshotID = nil; searchError = nil
        var visibleState = state
        visibleState.folderSidebarVisible = folderSidebarVisible
        workspace.stage(visibleState)
        if search { Task { await runSearch() }; focusSearch() }
    }

    func newSearchTab() {
        workspace.stage(workspaceSnapshot)
        var fresh = workspaceSnapshot; fresh.query = ""; fresh.customFilterID = nil
        if let state = workspace.newTab(state: fresh) { applyWorkspace(state) }
    }

    func closeSearchTab(_ id: UUID? = nil) {
        guard workspace.window.tabs.count > 1 else { return }
        workspace.stage(workspaceSnapshot)
        let target = id ?? workspace.window.selectedTabID
        let selected = target == workspace.window.selectedTabID
        let state = workspace.closeTab(target)
        if selected { applyWorkspace(state) }
    }

    func selectSearchTab(_ id: UUID) {
        workspace.stage(workspaceSnapshot)
        if let state = workspace.selectTab(id) { applyWorkspace(state) }
    }

    func selectAdjacentSearchTab(_ offset: Int) {
        let window = workspace.window
        guard let i = window.tabs.firstIndex(where: { $0.id == window.selectedTabID }) else { return }
        let next = (i + offset % window.tabs.count + window.tabs.count) % window.tabs.count
        selectSearchTab(window.tabs[next].id)
    }

    func historyBack() { if let state = workspace.back() { applyWorkspace(state) } }
    func historyForward() { if let state = workspace.forward() { applyWorkspace(state) } }
    func openHistorySearch(_ entry: SearchHistoryEntry) { applyWorkspace(entry.state); workspace.recordNow(entry.state) }

    @discardableResult func saveCurrentSearch(name: String, macroName: String = "", isCustomFilter: Bool = false) throws -> SavedSearch {
        let saved = SavedSearch(name: name, state: workspaceSnapshot, macroName: macroName, isCustomFilter: isCustomFilter)
        try workspace.library.saveSearch(saved); return saved
    }

    func openSavedSearch(_ saved: SavedSearch) { applyWorkspace(saved.state); workspace.recordNow(saved.state) }
    func applySavedFilter(_ id: UUID?) {
        var state = workspaceSnapshot; state.customFilterID = id
        applyWorkspace(state)
    }

    func setSearchFilter(_ filter: SearchFilter) {
        var filters = searchFilters
        filters = SearchFilters(types: filter == .all ? SearchFilters.allTypes : [filter], over: filters.over, under: filters.under)
        setSearchFilters(filters)
    }

    func toggleSearchFilter(_ filter: SearchFilter) {
        var filters = searchFilters
        filters.selectType(filter, selected: filter == .all || !filters.selectedTypes.contains(filter))
        setSearchFilters(filters, customFilterID: filter == .all ? nil : workspace.window.selectedTab.state.customFilterID)
    }

    func setSearchFilters(_ filters: SearchFilters, customFilterID: UUID? = nil, options: SearchWorkspaceState? = nil) {
        guard filters.validationError == nil else { return }
        var state = workspaceSnapshot
        state.filters = filters
        state.searchFilter = filters.types.count == 1 ? filters.types.first ?? .all : .all
        state.customFilterID = customFilterID
        if let options {
            state.matchPath = options.matchPath; state.caseSensitive = options.caseSensitive
            state.wholeWord = options.wholeWord; state.fuzzy = options.fuzzy
        }
        applyWorkspace(state)
        savePrefs()
    }

    func resolvedWorkspaceQuery() throws -> Query {
        try SearchMacroExpansion(savedSearches: workspace.library.archive.savedSearches).resolve(workspaceSnapshot)
    }

    // Source: categories and bounds are saved workspace choices; custom labels
    // are actual saved-search names or the macro resolver's missing-filter error.
    func filterSummary(for state: SearchWorkspaceState) -> String {
        var pieces: [String] = state.effectiveFilters.isEmpty ? [] : [state.effectiveFilters.summary]
        if let id = state.customFilterID {
            pieces.append(workspace.library.archive.savedSearches.first { $0.id == id && $0.isCustomFilter }?.name
                ?? SearchMacroError.missingFilter.localizedDescription)
        }
        return pieces.isEmpty ? SearchFilter.all.title : pieces.joined(separator: ", ")
    }

    var workspaceExpansionError: String? {
        do { _ = try resolvedWorkspaceQuery(); return nil }
        catch { return error.localizedDescription }
    }

    func persistWorkspace() { workspace.stage(workspaceSnapshot); workspace.library.flush() }
}
