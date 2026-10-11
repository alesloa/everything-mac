import SwiftUI
import IndexCore

// Source: fixed labels are application definitions; history text/options and dates come from recorded owner searches and their actual completion timestamps.
struct SearchHistoryView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { SearchHistoryLibraryView(library: model.workspace.library).environmentObject(model) }
}

private struct SearchHistoryLibraryView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var library: WorkspaceLibrary
    @State private var search = ""
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Find in search history", text: $search)
                Button("Clear history", role: .destructive) { library.clearHistory() }
                    .disabled(library.archive.history.isEmpty)
            }
            List(selection: $selection) {
                ForEach(library.archive.history.filter { search.isEmpty || $0.state.query.localizedCaseInsensitiveContains(search) }) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.state.query.isEmpty ? entry.state.searchFilter.title : entry.state.query).lineLimit(2)
                            Text(entry.completedAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.state.searchFilter.title).foregroundStyle(.secondary)
                    }.tag(entry.id)
                        .onTapGesture(count: 2) { model.openHistorySearch(entry) }
                        .contextMenu {
                            Button("Open search") { model.openHistorySearch(entry) }
                            Button("Delete", role: .destructive) { library.deleteHistory(entry.id) }
                        }
                }
            }
            if library.archive.history.isEmpty {
                Text(library.archive.historyPolicy.enabled ? "Completed searches appear here." : "Search history is disabled.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Open search") {
                    if let entry = library.archive.history.first(where: { $0.id == selection }) { model.openHistorySearch(entry) }
                }.disabled(!library.archive.history.contains { $0.id == selection })
                Spacer()
            }
            if let error = library.storageError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(20).frame(minWidth: 620, minHeight: 360)
    }
}

// Source: these interface labels and ranges describe the history/session behavior defined in SearchHistoryPolicy and SearchWorkspaceArchive.
struct WorkspaceSettingsView: View {
    @ObservedObject var library: WorkspaceLibrary

    var body: some View {
        Form {
            Section("Session") {
                Toggle("Restore windows and tabs on launch", isOn: Binding(
                    get: { library.archive.restoreSession }, set: { library.setRestoreSession($0) }))
            }
            Section("Search history") {
                Toggle("Keep completed searches", isOn: Binding(get: { library.archive.historyPolicy.enabled }, set: {
                    var policy = library.archive.historyPolicy; policy.enabled = $0; library.setHistoryPolicy(policy)
                }))
                Stepper("Maximum searches: \(library.archive.historyPolicy.maximumEntries)", value: Binding(
                    get: { library.archive.historyPolicy.maximumEntries }, set: {
                        var policy = library.archive.historyPolicy; policy.maximumEntries = $0; library.setHistoryPolicy(policy)
                    }), in: 1...10_000)
                Stepper("Retain for \(library.archive.historyPolicy.retentionDays) days", value: Binding(
                    get: { library.archive.historyPolicy.retentionDays }, set: {
                        var policy = library.archive.historyPolicy; policy.retentionDays = $0; library.setHistoryPolicy(policy)
                    }), in: 1...3650)
                Button("Clear search history", role: .destructive) { library.clearHistory() }
            }
            if let error = library.storageError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.formStyle(.grouped).padding(20)
    }
}
