import SwiftUI
import IndexCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var fdaGranted = true

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
            SearchField(text: $model.query, matchPath: $model.matchPath) { model.queryChanged() }
            Divider()
            ResultsTable(rows: model.results,
                         onSort: { k, a in model.sortKey = k; model.ascending = a; Task { await model.runSearch() } },
                         onActivate: { ResultActions.open($0) })
            Divider()
            StatusBar(total: model.total, shown: model.results.count, scanning: model.scanning)
        }
        .background(.regularMaterial)
        .onAppear { fdaGranted = FullDiskAccess.isGranted() }
    }
}
