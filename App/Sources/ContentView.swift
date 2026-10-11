import SwiftUI
import IndexCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        if model.awaitingFullDiskAccess {
            FullDiskAccessView()
        } else {
            searchUI
        }
    }

    private var searchUI: some View {
        VStack(spacing: 0) {
            if !model.fdaGranted {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Grant Full Disk Access to index everything.")
                    Spacer()
                    Button("Open Settings") { FullDiskAccess.openSettings() }
                }
                .padding(8)
                .background(.yellow.opacity(0.2))
                Divider()
            }
            SearchField(text: $model.query, matchPath: $model.matchPath, fuzzy: $model.fuzzy,
                        wholeWord: model.wholeWord, focused: $searchFocused, onChange: { model.queryChanged() },
                        fuzzyAvailable: !(model.regex || model.matchPrefix || model.matchSuffix))
            WorkspaceTabBar()
            HStack {
                // Source: the built-in SearchFilter definitions and the owner's
                // approved advanced-search addition.
                Picker("Filter", selection: Binding(get: { model.searchFilter }, set: {
                    model.searchFilter = $0; model.searchOptionsChanged()
                })) {
                    ForEach(SearchFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(width: 210)
                Button("Advanced…") { model.activePanel = .advancedSearch }
                Spacer()
            }.padding(.horizontal, 8).padding(.bottom, 6)
            if let error = model.searchError {
                // Source: Query.validationError for the entered query.
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            Divider()
            SearchResultsArea(model: model)
            if ResultActions.state.isBusy {
                HStack {
                    // Source: the running task represented by FileActionState.isBusy.
                    ProgressView().controlSize(.small)
                    Text("File operation in progress")
                    Spacer()
                    Button("Cancel") { ResultActions.state.cancel() }
                }.padding(8)
            }
            Divider()
            StatusBar(total: model.total, shown: model.results.count, scanning: model.scanning,
                      shares: model.shares, matches: model.totalMatches)
        }
        .background(.regularMaterial)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusSearchSignal) { searchFocused = true }
        .onChange(of: model.actionRecords) { model.updateQuickLookSelection() }
        .sheet(item: $model.activePanel) { panel in
            featurePanel(panel).environmentObject(model)
        }
    }

    @ViewBuilder private func featurePanel(_ panel: AppFeaturePanel) -> some View {
        VStack(spacing: 0) {
            HStack { Spacer(); Button("Close") { model.activePanel = nil }.keyboardShortcut(.cancelAction) }.padding(10)
            switch panel {
            case .advancedSearch:
                AdvancedSearchView(initialQuery: advancedInitialQuery,
                onApply: {
                    model.query = $0; model.regex = false; model.searchFilter = .all
                    model.activePanel = nil; model.queryChanged()
                }, onCancel: { model.activePanel = nil })
            case .bookmarks: SavedSearchesView()
            case .history: SearchHistoryView()
            case .catalogs:
                switch model.featureQueryResult {
                case .success(let query):
                    CatalogBrowserView(store: model.catalogStore).onAppear {
                        model.catalogStore.configure(query: query, resultLimit: model.resultLimit)
                    }
                case .failure(let error): featureError(error)
                }
            case .export:
                switch model.featureQueryResult {
                case .success(let query):
                    NativeResultsExportView(index: model.index.searchIndex, query: query,
                        selected: model.actionRecords, shown: model.results,
                        sort: model.sortKey, ascending: model.ascending, folderPath: model.folderScope?.path)
                case .failure(let error): featureError(error)
                }
            case .duplicates:
                if case .failure(let error) = model.featureQueryResult { featureError(error) }
                DuplicateFinderView(index: model.index.searchIndex,
                    query: try? model.featureQueryResult.get(), selectedPaths: model.actionRecords.map(\.path),
                    folderPath: model.folderScope?.path)
            case .contentSearch:
                switch model.featureQueryResult {
                case .success(let query):
                    ContentSearchView(index: model.index.searchIndex,
                        query: query, selectedPaths: model.actionRecords.map(\.path),
                        folderPath: model.folderScope?.path)
                case .failure(let error): featureError(error)
                }
            case .activity: IndexActivityView(index: model.index)
            }
        }
    }

    private func featureError(_ error: Error) -> some View {
        // Source: saved-query expansion or Query.validationError for this window.
        Text(error.localizedDescription).foregroundStyle(.red).textSelection(.enabled).padding(20)
    }

    private var advancedInitialQuery: String {
        let query = model.currentQuery
        return query.regex ? "regex:\(Query.quotedLiteral(query.text))" : query.text
    }
}
