import SwiftUI

// Source: the owner's approved file-action additions; enabled states come from
// the actual selection and FileActionState's operation/undo state.
struct FileActionCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Rename…") { model.performSelected(.rename) }
                .disabled(model.selectionCount == 0 || model.selectionLoading || ResultActions.state.isBusy)
            Button("Get Info") { model.performSelected(.getInfo) }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(model.selectionCount == 0 || model.selectionLoading)
            Button("Copy To…") { model.performSelected(.copyTo) }
                .disabled(model.selectionCount == 0 || model.selectionLoading || ResultActions.state.isBusy)
            Button("Move To…") { model.performSelected(.moveTo) }
                .disabled(model.selectionCount == 0 || model.selectionLoading || ResultActions.state.isBusy)
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy Files") { model.performSelected(.copyFiles) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model.selectionCount == 0 || model.selectionLoading)
            Button("Paste Files…") { ResultActions.pasteFiles(into: model.selectionCount == 1 ? model.selected : nil) }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(!ResultActions.canPasteFiles || ResultActions.state.isBusy)
        }
        CommandGroup(after: .undoRedo) {
            Button("Undo File Operation") { ResultActions.undoLastOperation() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(!ResultActions.state.canUndo || ResultActions.state.isBusy)
            Button("Cancel File Operation") { model.cancelSelectionResolution(); ResultActions.state.cancel() }
                .disabled(!ResultActions.state.isBusy && !model.selectionLoading)
        }
    }
}
