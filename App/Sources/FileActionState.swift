import AppKit
import Observation

@Observable @MainActor final class FileActionState {
    private(set) var isBusy = false
    private(set) var canUndo = false
    private(set) var error: String?
    private let engine = FileOperationEngine()
    private var task: Task<Void, Never>?

    func perform(_ operation: FileOperation, title: String) {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        task = Task {
            let outcome = await engine.perform(operation)
            finish(outcome, title: title)
        }
    }

    func undo() {
        guard !isBusy, canUndo else { return }
        isBusy = true
        error = nil
        task = Task {
            let outcome = await engine.undo()
            finish(outcome, title: "Undo File Operation")
        }
    }

    func cancel() { task?.cancel() }

    func showError(_ message: String, title: String) {
        error = message
        let alert = NSAlert()
        // Source: the requested action's title and the filesystem/application API error.
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func finish(_ outcome: FileOperationOutcome, title: String) {
        canUndo = outcome.canUndo
        isBusy = false
        task = nil
        if !outcome.errors.isEmpty { showError(outcome.errors.joined(separator: "\n"), title: title) }
    }
}
