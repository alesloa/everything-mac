import SwiftUI
import IndexCore

// Live search defaults — these bind AppModel directly and re-run the current query
// the moment they change (no Apply / re-index needed). They share the exact same
// state the View-menu toggles and column headers drive, so everything stays in sync.
struct SearchSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Match options") {
                Toggle("Match case", isOn: caseBinding)
                Toggle("Match whole word", isOn: wholeBinding)
                Toggle("Search full path (not just the name)", isOn: matchPathBinding)
            }
            Section("Results") {
                Picker("Sort by", selection: sortBinding) {
                    Text("Name").tag(QueryEngine.SortKey.name)
                    Text("Path").tag(QueryEngine.SortKey.path)
                    Text("Size").tag(QueryEngine.SortKey.size)
                    Text("Kind").tag(QueryEngine.SortKey.kind)
                    Text("Date Modified").tag(QueryEngine.SortKey.mtime)
                }
                Picker("Order", selection: ascendingBinding) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                Stepper(value: limitBinding, in: 100...100_000, step: 100) {
                    LabeledContent("Max results shown", value: model.resultLimit.formatted())
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private var caseBinding: Binding<Bool> {
        Binding(get: { model.caseSensitive }, set: { model.caseSensitive = $0; model.searchOptionsChanged() })
    }
    private var wholeBinding: Binding<Bool> {
        Binding(get: { model.wholeWord }, set: { model.wholeWord = $0; model.searchOptionsChanged() })
    }
    private var matchPathBinding: Binding<Bool> {
        Binding(get: { model.matchPath }, set: { model.matchPath = $0; model.searchOptionsChanged() })
    }
    private var sortBinding: Binding<QueryEngine.SortKey> {
        Binding(get: { model.sortKey }, set: { model.setSort($0, ascending: model.ascending) })
    }
    private var ascendingBinding: Binding<Bool> {
        Binding(get: { model.ascending }, set: { model.setSort(model.sortKey, ascending: $0) })
    }
    private var limitBinding: Binding<Int> {
        Binding(get: { model.resultLimit }, set: { model.resultLimit = $0; model.searchOptionsChanged() })
    }
}
