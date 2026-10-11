import SwiftUI
import AppKit
import IndexCore

// The app's menu-bar commands. SwiftUI gives a bare File/Edit by default; this
// fills in the file/clipboard/view actions that operate on the selected result,
// the search field, and the index. Selection-dependent items disable when nothing
// is selected so the menu reflects what's actually actionable.
struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    private var sortBinding: Binding<QueryEngine.SortKey> {
        Binding(get: { model.sortKey },
                set: { model.setSort($0, ascending: model.ascending) })
    }
    private var matchPathBinding: Binding<Bool> {
        Binding(get: { model.matchPath },
                set: { model.matchPath = $0; model.searchOptionsChanged() })
    }
    private var caseSensitiveBinding: Binding<Bool> {
        Binding(get: { model.caseSensitive },
                set: { model.caseSensitive = $0; model.searchOptionsChanged() })
    }
    private var wholeWordBinding: Binding<Bool> {
        Binding(get: { model.wholeWord },
                set: { model.wholeWord = $0; model.searchOptionsChanged() })
    }
    private var fuzzyBinding: Binding<Bool> {
        Binding(get: { model.fuzzy }, set: { model.fuzzy = $0; model.searchOptionsChanged() })
    }

    var body: some Commands {
        // FILE — act on the selected result, plus index/export actions.
        CommandGroup(after: .newItem) {
            Divider()
            Button("Open") { ResultActions.open(model.actionRecords) }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.actionRecords.isEmpty)
            Button("Reveal in Finder") { ResultActions.reveal(model.actionRecords) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.actionRecords.isEmpty)
            Divider()
            Button("Export Results…") { model.activePanel = .export }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.results.isEmpty)
            Button(model.scanning ? "Rebuilding Index…" : "Rebuild Index") { model.rebuildIndex() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(model.scanning)
            Divider()
            // No keyboard shortcut on purpose: ⌘⌫ is "delete to start of line" while
            // the search field is focused, so binding it here would risk trashing a
            // file mid-type. Click-only keeps a destructive action deliberate.
            Button("Move to Trash") { ResultActions.trash(model.actionRecords) }
                .disabled(model.actionRecords.isEmpty || ResultActions.state.isBusy)
        }

        // EDIT — copy path/name of the selection, after the standard clipboard group.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Path") { ResultActions.copyPath(model.actionRecords) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.actionRecords.isEmpty)
            Button("Copy Name") { ResultActions.copyName(model.actionRecords) }
                .disabled(model.actionRecords.isEmpty)
        }
        CommandGroup(after: .textEditing) {
            Button("Find") { model.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }

        // VIEW — sort order + path matching, mirroring the column headers and the
        // search field's "Match path" switch so they stay in lockstep.
        CommandMenu("View") {
            Menu("Sort By") {
                Picker("Sort By", selection: sortBinding) {
                    // Source: QueryEngine's fuzzy score and the owner's search request.
                    Text("Relevance").tag(QueryEngine.SortKey.relevance)
                    Text("Name").tag(QueryEngine.SortKey.name)
                    Text("Path").tag(QueryEngine.SortKey.path)
                    Text("Size").tag(QueryEngine.SortKey.size)
                    Text("Kind").tag(QueryEngine.SortKey.kind)
                    Text("Date Modified").tag(QueryEngine.SortKey.mtime)
                }
                .pickerStyle(.inline)
            }
            Button(model.sortKey == .relevance
                   ? (model.ascending ? "Best Match Last" : "Best Match First")
                   : (model.ascending ? "Sort Descending" : "Sort Ascending")) {
                model.setSort(model.sortKey, ascending: !model.ascending)
            }
            Divider()
            Toggle("Match Path", isOn: matchPathBinding)
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Toggle("Match Case", isOn: caseSensitiveBinding)
            Toggle("Match Whole Word", isOn: wholeWordBinding)
            Toggle("Fuzzy Matching", isOn: fuzzyBinding)
                .disabled(model.wholeWord || model.regex || model.matchPrefix || model.matchSuffix)
            Divider()
            // Source: the owner's requested native previews and thumbnail view.
            Toggle("Preview", isOn: Binding(get: { model.previewVisible }, set: {
                model.previewVisible = $0; model.savePrefs()
            }))
                .keyboardShortcut("p", modifiers: [.command, .option])
            Toggle("Thumbnails", isOn: Binding(get: { model.thumbnailView }, set: {
                model.thumbnailView = $0; model.savePrefs()
            }))
        }

        SearchFeatureCommands(model: model)
        FileActionCommands(model: model)
        WorkspaceCommands(model: model)

        // HELP — point at the project instead of the empty default Help menu.
        CommandGroup(replacing: .help) {
            Button("EverythingMac Help") { Self.open("https://github.com/alesloa/everything-mac") }
            Button("Report an Issue…") { Self.open("https://github.com/alesloa/everything-mac/issues/new") }
        }
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}
