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
                        wholeWord: model.wholeWord, focused: $searchFocused) { model.queryChanged() }
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
            ResultsTable(rows: model.results,
                         onSort: { k, a in model.setSort(k, ascending: a) },
                         onSelect: { model.selectedID = $0?.id },
                         onActivate: { ResultActions.open($0) },
                         onSelection: { model.selectRecords($0) })
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
                      shares: model.shares)
        }
        .background(.regularMaterial)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusSearchSignal) { searchFocused = true }
        .sheet(isPresented: Binding(get: { model.activePanel == .advancedSearch }, set: {
            if !$0 { model.activePanel = nil }
        })) {
            AdvancedSearchView(initialQuery: advancedInitialQuery,
                onApply: {
                    model.query = $0; model.regex = false; model.searchFilter = .all
                    model.activePanel = nil; model.queryChanged()
                }, onCancel: { model.activePanel = nil })
        }
    }

    private var advancedInitialQuery: String {
        let query = model.currentQuery
        return query.regex ? "regex:\(Query.quotedLiteral(query.text))" : query.text
    }
}
