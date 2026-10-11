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
        state.searchFilter = searchFilter; state.customFilterID = workspace.window.selectedTab.state.customFilterID
        state.sortKey = Self.sortKeyName(sortKey); state.ascending = ascending; state.resultLimit = resultLimit
        state.previewVisible = previewVisible; state.thumbnailView = thumbnailView
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
        searchFilter = state.searchFilter; sortKey = Self.sortKey(from: state.sortKey); ascending = state.ascending
        resultLimit = state.resultLimit; previewVisible = state.previewVisible; thumbnailView = state.thumbnailView
        selectedRecords = []; selectedID = nil; results = []
        workspace.stage(state)
        if search { Task { await runSearch() }; focusSearch() }
    }

    func newSearchTab() {
        workspace.stage(workspaceSnapshot)
        var fresh = workspaceSnapshot; fresh.query = ""; fresh.customFilterID = nil
        if let state = workspace.newTab(state: fresh) { applyWorkspace(state) }
    }

    func closeSearchTab(_ id: UUID? = nil) {
        workspace.stage(workspaceSnapshot)
        applyWorkspace(workspace.closeTab(id ?? workspace.window.selectedTabID))
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

    func resolvedWorkspaceQuery() throws -> Query {
        try SearchMacroExpansion(savedSearches: workspace.library.archive.savedSearches).resolve(workspaceSnapshot)
    }

    var workspaceExpansionError: String? {
        do { _ = try resolvedWorkspaceQuery(); return nil }
        catch { return error.localizedDescription }
    }

    func persistWorkspace() { workspace.stage(workspaceSnapshot); workspace.library.flush() }
}
