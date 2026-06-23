import SwiftUI
import IndexCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var fdaGranted = true
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !fdaGranted {
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
            SearchField(text: $model.query, matchPath: $model.matchPath, focused: $searchFocused) { model.queryChanged() }
            Divider()
            ResultsTable(rows: model.results,
                         onSort: { k, a in model.setSort(k, ascending: a) },
                         onSelect: { model.selectedID = $0?.id },
                         onActivate: { ResultActions.open($0) })
            Divider()
            StatusBar(total: model.total, shown: model.results.count, scanning: model.scanning)
        }
        .background(.regularMaterial)
        .onAppear {
            fdaGranted = FullDiskAccess.isGranted()
            searchFocused = true
        }
        .onChange(of: model.focusSearchSignal) { searchFocused = true }
    }
}
