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
                set: { model.sortKey = $0; Task { await model.runSearch() } })
    }
    private var matchPathBinding: Binding<Bool> {
        Binding(get: { model.matchPath },
                set: { model.matchPath = $0; Task { await model.runSearch() } })
    }

    var body: some Commands {
        // FILE — act on the selected result, plus index/export actions.
        CommandGroup(after: .newItem) {
            Divider()
            Button("Open") { if let r = model.selected { ResultActions.open(r) } }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.selected == nil)
            Button("Reveal in Finder") { if let r = model.selected { ResultActions.reveal(r) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selected == nil)
            Divider()
            Button("Export Results…") { ResultActions.exportResults(model.results) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.results.isEmpty)
            Button(model.scanning ? "Rebuilding Index…" : "Rebuild Index") { model.rebuildIndex() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(model.scanning)
            Divider()
            // No keyboard shortcut on purpose: ⌘⌫ is "delete to start of line" while
            // the search field is focused, so binding it here would risk trashing a
            // file mid-type. Click-only keeps a destructive action deliberate.
            Button("Move to Trash") { if let r = model.selected { ResultActions.trash(r) } }
                .disabled(model.selected == nil)
        }

        // EDIT — copy path/name of the selection, after the standard clipboard group.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Path") { if let r = model.selected { ResultActions.copyPath(r) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.selected == nil)
            Button("Copy Name") { if let r = model.selected { ResultActions.copyName(r) } }
                .disabled(model.selected == nil)
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
                    Text("Name").tag(QueryEngine.SortKey.name)
                    Text("Path").tag(QueryEngine.SortKey.path)
                    Text("Size").tag(QueryEngine.SortKey.size)
                    Text("Kind").tag(QueryEngine.SortKey.kind)
                    Text("Date Modified").tag(QueryEngine.SortKey.mtime)
                }
                .pickerStyle(.inline)
            }
            Button(model.ascending ? "Sort Descending" : "Sort Ascending") {
                model.ascending.toggle(); Task { await model.runSearch() }
            }
            Divider()
            Toggle("Match Path", isOn: matchPathBinding)
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }

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
