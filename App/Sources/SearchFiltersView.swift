import SwiftUI
import IndexCore

// Source: labels are application interface definitions; category names and units
// come from SearchFilters, and displayed selections and sizes are owner-entered.
struct SearchFiltersEditor: View {
    @Binding var filters: SearchFilters

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("File types").font(.headline)
                Spacer()
                Toggle("Everything", isOn: Binding(get: { filters.everythingSelected },
                    set: { filters.selectAllTypes($0) })).toggleStyle(.checkbox)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(SearchFilter.allCases.filter { $0 != .all }, id: \.self) { filter in
                    Toggle(filter.title, isOn: Binding(get: { filters.selectedTypes.contains(filter) }, set: {
                        filters.selectType(filter, selected: $0)
                    })).toggleStyle(.checkbox)
                }
            }
            Text("Match any selected type. Files includes all file types.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("File size").font(.headline)
            sizeRow("Over", keyPath: \.over)
            sizeRow("Under", keyPath: \.under)
            Text("Size limits apply to files. MB and GB use decimal bytes.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = filters.validationError {
                Text(error.localizedDescription).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sizeRow(_ title: String, keyPath: WritableKeyPath<SearchFilters, SearchSizeLimit?>) -> some View {
        HStack {
            Toggle(title, isOn: Binding(get: { filters[keyPath: keyPath] != nil }, set: {
                filters[keyPath: keyPath] = $0 ? SearchSizeLimit() : nil
            })).toggleStyle(.checkbox).frame(width: 70, alignment: .leading)
            TextField("Size", text: Binding(get: { filters[keyPath: keyPath]?.amount ?? "" }, set: {
                filters[keyPath: keyPath]?.amount = $0
            })).textFieldStyle(.roundedBorder).accessibilityLabel("\(title) size")
                .disabled(filters[keyPath: keyPath] == nil)
            Picker("Unit", selection: Binding(get: { filters[keyPath: keyPath]?.unit ?? .megabytes }, set: {
                filters[keyPath: keyPath]?.unit = $0
            })) {
                ForEach(SearchSizeLimit.Unit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden().frame(width: 70).accessibilityLabel("\(title) size unit")
                .disabled(filters[keyPath: keyPath] == nil)
        }
    }
}

struct SearchFiltersButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workspace: SearchWorkspaceController
    @State private var presented = false

    private var count: Int {
        model.searchFilters.activeCount + (workspace.window.selectedTab.state.customFilterID == nil ? 0 : 1)
    }
    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 5) {
                Label("Filters", systemImage: "line.3.horizontal.decrease")
                if count > 0 { Text(count.formatted()).monospacedDigit() }
            }
        }
        .fixedSize().help(model.filterSummary(for: model.workspaceSnapshot))
        .accessibilityLabel("Filters: \(model.filterSummary(for: model.workspaceSnapshot))")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            SearchFiltersPopover(model: model, workspace: workspace) { presented = false }
        }
    }
}

struct SearchFiltersPopover: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workspace: SearchWorkspaceController
    let close: () -> Void
    @State private var draft: SearchFilters
    @State private var customFilterID: UUID?
    @State private var options: SearchWorkspaceState

    init(model: AppModel, workspace: SearchWorkspaceController, close: @escaping () -> Void) {
        self.model = model; self.workspace = workspace; self.close = close
        _draft = State(initialValue: model.searchFilters)
        _customFilterID = State(initialValue: workspace.window.selectedTab.state.customFilterID)
        _options = State(initialValue: model.workspaceSnapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Filters").font(.title3.bold())
            SearchFiltersEditor(filters: $draft)
            let saved = workspace.library.archive.savedSearches.filter(\.isCustomFilter)
            if !saved.isEmpty {
                // Source: names and identifiers are actual saved custom filters.
                Picker("Saved filter", selection: $customFilterID) {
                    Text("None").tag(nil as UUID?)
                    ForEach(saved) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            Divider()
            HStack {
                Toggle("Match Path", isOn: option(\.matchPath))
                Toggle("Match Case", isOn: option(\.caseSensitive))
            }.toggleStyle(.checkbox)
            HStack {
                Toggle("Whole Word", isOn: option(\.wholeWord))
                Toggle("Fuzzy Matching", isOn: option(\.fuzzy))
                    .disabled(options.wholeWord || options.regex || options.matchPrefix || options.matchSuffix)
                    .help("Allows gaps between letters; turn off for consecutive text matching.")
            }.toggleStyle(.checkbox)
            // Source: FuzzyMatcher's subsequence matching and the owner's expo search complaint.
            Text("Fuzzy matching allows gaps between letters.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Advanced Search…") { close(); model.activePanel = .advancedSearch }
                Spacer()
                Button("New Tab") { close(); model.newSearchTab() }.disabled(!workspace.canAddTab)
            }.buttonStyle(.link)
            Divider()
            HStack {
                Button("Clear All") { draft = SearchFilters(); customFilterID = nil }
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Apply") { model.setSearchFilters(draft, customFilterID: customFilterID, options: options); close() }
                    .keyboardShortcut(.defaultAction).disabled(draft.validationError != nil)
            }
        }.padding(16).frame(width: 330)
    }

    private func option(_ keyPath: WritableKeyPath<SearchWorkspaceState, Bool>) -> Binding<Bool> {
        Binding(get: { options[keyPath: keyPath] }, set: { options[keyPath: keyPath] = $0 })
    }
}
