import IndexCore

extension AppModel {
    func selectRows(_ selection: SearchRowSelection) {
        guard selection.list === resultList else { return }
        rowSelection = selection.count == 0 ? nil : selection
        selectedRecords = selection.preview; selectedID = selectedRecords.first?.id
        selectionGeneration &+= 1
        updateQuickLookSelection()
    }

    func performSelected(_ action: ResultSelectionAction) {
        if let rowSelection { resolveSelection(rowSelection) { action.perform($0) } }
        else { action.perform(actionRecords) }
    }

    func performRows(_ selection: SearchRowSelection, _ action: ResultSelectionAction) {
        resolveSelection(selection) { action.perform($0) }
    }

    func openSelectedPanel(_ panel: AppFeaturePanel) {
        guard let rowSelection else { panelRecords = actionRecords; activePanel = panel; return }
        resolveSelection(rowSelection) { [weak self] in self?.panelRecords = $0; self?.activePanel = panel }
    }

    func cancelSelectionResolution() {
        selectionResolution?.cancel(); selectionResolution = nil; selectionLoading = false
    }

    private func resolveSelection(_ selection: SearchRowSelection, action: @escaping @MainActor ([FileRecord]) -> Void) {
        cancelSelectionResolution()
        let preview = selection.preview
        if preview.count == selection.count { action(preview); return }
        selectionLoading = true
        selectionResolution = Task { [weak self] in
            let records = await selection.records()
            guard !Task.isCancelled, let self else { return }
            self.selectionLoading = false; self.selectionResolution = nil
            guard records.count == selection.count else { return }
            action(records)
        }
    }
}
