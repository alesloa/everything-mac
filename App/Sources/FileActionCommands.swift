import SwiftUI

// Source: the owner's approved file-action additions; enabled states come from
// the actual selection and FileActionState's operation/undo state.
struct FileActionCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Rename…") { ResultActions.rename(model.actionRecords) }
                .disabled(model.actionRecords.isEmpty || ResultActions.state.isBusy)
            Button("Get Info") { ResultActions.getInfo(model.actionRecords) }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(model.actionRecords.isEmpty)
            Button("Copy To…") { ResultActions.copyTo(model.actionRecords) }
                .disabled(model.actionRecords.isEmpty || ResultActions.state.isBusy)
            Button("Move To…") { ResultActions.moveTo(model.actionRecords) }
                .disabled(model.actionRecords.isEmpty || ResultActions.state.isBusy)
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy Files") { ResultActions.copyFiles(model.actionRecords) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model.actionRecords.isEmpty)
            Button("Paste Files…") { ResultActions.pasteFiles(into: model.selected) }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(!ResultActions.canPasteFiles || ResultActions.state.isBusy)
        }
        CommandGroup(after: .undoRedo) {
            Button("Undo File Operation") { ResultActions.undoLastOperation() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(!ResultActions.state.canUndo || ResultActions.state.isBusy)
            Button("Cancel File Operation") { ResultActions.state.cancel() }
                .disabled(!ResultActions.state.isBusy)
        }
    }
}
