import SwiftUI
import IndexCore

// Source: fixed labels are application definitions; displayed search names, macros, queries and options come from the owner's saved searches.
struct SavedSearchesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { SavedSearchLibraryView(library: model.workspace.library).environmentObject(model) }
}

private struct SavedSearchLibraryView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var library: WorkspaceLibrary
    @State private var editing: SavedSearch?
    @State private var selection: UUID?
    @State private var search = ""

    private var searches: [SavedSearch] {
        library.archive.savedSearches.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
            || $0.state.query.localizedCaseInsensitiveContains(search) || $0.macroName.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Find saved searches", text: $search)
                Button("Save current search") { editing = SavedSearch(name: "", state: model.workspaceSnapshot) }
            }
            List(selection: $selection) {
                ForEach(searches) { saved in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(saved.name).font(.headline)
                            if saved.isCustomFilter { Image(systemName: "line.3.horizontal.decrease.circle").help("Saved filter") }
                            Spacer()
                            if !saved.macroName.isEmpty { Text("macro:" + saved.macroName).font(.system(.caption, design: .monospaced)) }
                        }
                        Text(saved.state.query).lineLimit(2).foregroundStyle(.secondary)
                    }.padding(.vertical, 4).tag(saved.id)
                        .contextMenu {
                            Button("Open search") { model.openSavedSearch(saved) }
                            Button("Edit") { editing = saved }
                            if saved.isCustomFilter { Button("Apply as filter") { model.applySavedFilter(saved.id) } }
                            Button("Delete", role: .destructive) { library.deleteSearch(saved.id) }
                        }
                        .onTapGesture(count: 2) { model.openSavedSearch(saved) }
                }
            }
            if library.archive.savedSearches.isEmpty { Text("Save a search to keep its query and options.").foregroundStyle(.secondary) }
            HStack {
                Button("Open") { if let saved = selected { model.openSavedSearch(saved) } }.disabled(selected == nil)
                Button("Edit") { editing = selected }.disabled(selected == nil)
                Button("Delete", role: .destructive) { if let saved = selected { library.deleteSearch(saved.id) } }.disabled(selected == nil)
                Spacer()
            }
            if let error = library.storageError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(20).frame(minWidth: 620, minHeight: 360)
        .sheet(item: $editing) { saved in SavedSearchEditor(saved: saved, library: library) }
    }

    private var selected: SavedSearch? { library.archive.savedSearches.first { $0.id == selection } }
}

private struct SavedSearchEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: WorkspaceLibrary
    @State private var saved: SavedSearch
    @State private var error: String?

    init(saved: SavedSearch, library: WorkspaceLibrary) { self.library = library; _saved = State(initialValue: saved) }

    var body: some View {
        VStack(spacing: 12) {
            Text("Saved search").font(.title2)
            Form {
                TextField("Name", text: $saved.name)
                TextField("Query", text: $saved.state.query, axis: .vertical).lineLimit(2...5)
                TextField("Macro name", text: $saved.macroName)
                Text("Use macro:name in a query to insert the saved query.").font(.caption).foregroundStyle(.secondary)
                Toggle("Show as a custom filter", isOn: $saved.isCustomFilter)
                Picker("Saved filter", selection: $saved.state.customFilterID) {
                    Text("None").tag(Optional<UUID>.none)
                    ForEach(library.archive.savedSearches.filter { $0.isCustomFilter && $0.id != saved.id }) { filter in
                        Text(filter.name).tag(Optional(filter.id))
                    }
                }
                WorkspaceStateOptions(state: $saved.state)
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try library.saveSearch(saved)
                        if library.storageError == nil { dismiss() }
                        else { error = library.storageError }
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(saved.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || saved.state.effectiveFilters.validationError != nil)
            }
        }.padding(20).frame(width: 640, height: 660)
    }
}

private struct WorkspaceStateOptions: View {
    @Binding var state: SearchWorkspaceState
    var body: some View {
        DisclosureGroup("Filters") {
            SearchFiltersEditor(filters: Binding(get: { state.effectiveFilters }, set: {
                state.filters = $0
                state.searchFilter = $0.types.count == 1 ? $0.types.first ?? .all : .all
            }))
        }
        DisclosureGroup("Match options") {
            Toggle("Match path", isOn: $state.matchPath)
            Toggle("Match case", isOn: $state.caseSensitive)
            Toggle("Match whole word", isOn: $state.wholeWord)
            Toggle("Fuzzy matching", isOn: $state.fuzzy)
                .disabled(state.wholeWord || state.regex || state.matchPrefix || state.matchSuffix)
            Toggle("Regular expression", isOn: $state.regex)
            Toggle("Ignore diacritics", isOn: $state.diacriticInsensitive)
            Toggle("Match prefix", isOn: $state.matchPrefix)
            Toggle("Match suffix", isOn: $state.matchSuffix)
            Toggle("Ignore punctuation", isOn: $state.ignorePunctuation)
            Toggle("Ignore whitespace", isOn: $state.ignoreWhitespace)
        }
        DisclosureGroup("Results and appearance") {
            Picker("Sort by", selection: $state.sortKey) {
                Text("Relevance").tag("relevance"); Text("Name").tag("name"); Text("Path").tag("path")
                Text("Size").tag("size"); Text("Date modified").tag("mtime"); Text("Kind").tag("kind")
            }
            Toggle("Ascending order", isOn: $state.ascending)
            Toggle("Show preview", isOn: $state.previewVisible)
            Toggle("Show thumbnails", isOn: $state.thumbnailView)
            // Source: the saved view/scope values defined by SearchWorkspaceState.
            Toggle("Show folder sidebar", isOn: Binding(get: { state.folderSidebarVisible ?? false },
                set: { state.folderSidebarVisible = $0 }))
            Toggle("Show indexed folder totals", isOn: Binding(get: { state.indexedFolderTotals ?? false },
                set: { state.indexedFolderTotals = $0 }))
            if let path = state.folderScopePath {
                LabeledContent("Folder scope", value: path)
                Button("Clear folder scope") { state.folderScopePath = nil }
            }
        }
    }
}
