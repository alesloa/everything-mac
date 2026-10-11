import SwiftUI

// Source: the owner's approved tabs, saved searches, and history features;
// enabled state comes from the current SearchWorkspaceController.
struct WorkspaceCommands: Commands {
    @ObservedObject var model: AppModel
    var body: some Commands { WorkspaceMenuCommands(model: model, workspace: model.workspace) }
}

private struct WorkspaceMenuCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var workspace: SearchWorkspaceController
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Search Tab") { model.newSearchTab() }
                .keyboardShortcut("t", modifiers: .command).disabled(!workspace.canAddTab)
            Button("Close Search Tab") { model.closeSearchTab() }
                .keyboardShortcut("w", modifiers: [.command, .shift]).disabled(workspace.window.tabs.count < 2)
            Button("Next Search Tab") { model.selectAdjacentSearchTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Search Tab") { model.selectAdjacentSearchTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }
        CommandMenu("Bookmarks") {
            Button("Saved Searches…") { model.activePanel = .bookmarks }
                .keyboardShortcut("d", modifiers: .command)
            Divider()
            ForEach(workspace.library.archive.savedSearches) { saved in
                Button(saved.name) { model.openSavedSearch(saved) }
            }
        }
        CommandMenu("History") {
            Button("Back") { model.historyBack() }
                .keyboardShortcut("[", modifiers: .command).disabled(!workspace.canGoBack)
            Button("Forward") { model.historyForward() }
                .keyboardShortcut("]", modifiers: .command).disabled(!workspace.canGoForward)
            Button("Search History…") { model.activePanel = .history }
        }
    }
}
