import SwiftUI
import IndexCore

// Source: the owner's approved advanced-search and file-type-filter additions;
// filter names and parser behavior come from IndexCore's SearchFilter and Query.
struct SearchFeatureCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandMenu("Search") {
            Button("Advanced Search…") { model.activePanel = .advancedSearch }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Menu("Filters") {
                Toggle("Everything", isOn: Binding(get: { model.searchFilters.everythingSelected }, set: {
                    var filters = model.searchFilters; filters.selectAllTypes($0)
                    model.setSearchFilters(filters, customFilterID: model.workspaceSnapshot.customFilterID)
                }))
                ForEach(SearchFilter.allCases.filter { $0 != .all }, id: \.self) { filter in
                    Toggle(filter.title, isOn: Binding(get: { model.searchFilters.selectedTypes.contains(filter) },
                        set: { _ in model.toggleSearchFilter(filter) }))
                }
            }
            Divider()
            Toggle("Regular Expressions", isOn: option(\.regex))
            Toggle("Ignore Diacritics", isOn: option(\.diacriticInsensitive))
            Toggle("Match Prefix", isOn: option(\.matchPrefix))
            Toggle("Match Suffix", isOn: option(\.matchSuffix))
            Toggle("Ignore Punctuation", isOn: option(\.ignorePunctuation))
            Toggle("Ignore Whitespace", isOn: option(\.ignoreWhitespace))
        }
        CommandMenu("Tools") {
            Button("Find Duplicates…") { model.openSelectedPanel(.duplicates) }
            Button("Search File Contents…") { model.openSelectedPanel(.contentSearch) }
            Button("File Catalogs…") { model.activePanel = .catalogs }
            Divider()
            Button("Index Activity…") { model.activePanel = .activity }
        }
    }

    private func option(_ keyPath: ReferenceWritableKeyPath<AppModel, Bool>) -> Binding<Bool> {
        Binding(get: { model[keyPath: keyPath] }, set: {
            model[keyPath: keyPath] = $0; model.searchOptionsChanged()
        })
    }
}
