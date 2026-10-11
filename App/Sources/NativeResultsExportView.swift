import SwiftUI
import AppKit
import UniformTypeIdentifiers
import IndexCore

/// Labels implement the owner's requested native selected/shown/full exports.
/// Query, sorting and row counts come from the captured native search state.
struct NativeResultsExportView: View {
    let index: SearchIndex
    let query: Query
    let selected: [FileRecord]
    let shown: [FileRecord]
    var sort: QueryEngine.SortKey = .relevance
    var ascending = true
    var folderPath: String? = nil
    var selection: SearchRowSelection? = nil
    @State private var format: CatalogFormat = .csv
    @State private var scope: CatalogExportScope = .allMatching
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var cancellation: CatalogWorkCancellation?
    @State private var operation: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export results").font(.title2)
            Picker("Rows", selection: $scope) { ForEach(CatalogExportScope.allCases) { Text($0.label).tag($0) } }
            Picker("Format", selection: $format) { ForEach(CatalogFormat.allCases) { Text($0.label).tag($0) } }
            // These numbers come from the captured selection and shown arrays.
            Text("\((selection?.count ?? selected.count).formatted()) selected · \(shown.count.formatted()) shown").font(.caption).foregroundStyle(.secondary)
            Text(query.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            // This behavior description comes from CatalogIO.exportNative.
            Text("All matching rows exports the complete query in the current sort order. Shown rows exports the visible rows.")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button(isWorking ? "Cancel operation" : "Cancel") {
                    if isWorking { cancellation?.cancel(); operation?.cancel() } else { dismiss() }
                }
                Button("Save…", action: save).disabled(isWorking || (scope == .selected && (selection?.count ?? selected.count) == 0))
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 470)
        .onDisappear { cancellation?.cancel(); operation?.cancel() }
    }

    private func save() {
        let selection = selection?.pinned()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue)].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let cancellation = CatalogWorkCancellation(), format = format, scope = scope
        let namespace = UUID(), records = (scope == .selected ? selected : shown).map { CatalogRecord(native: $0, catalogID: namespace) }
        self.cancellation = cancellation; isWorking = true; errorMessage = nil
        operation = Task {
            do {
                if scope == .selected, let selection {
                    let ready = await withTaskCancellationHandler { await selection.list.prepare() }
                        onCancel: { selection.list.cancel() }
                    if !ready { throw CancellationError() }
                }
                _ = try await Task.detached(priority: .utility) {
                    if scope == .selected, let selection {
                        return try CatalogIO.exportSelection(selection, to: url, format: format,
                                                             isCancelled: { cancellation.isCancelled })
                    }
                    if scope == .allMatching {
                        return try CatalogIO.exportNative(store: index.readSnapshot(), query: query, sort: sort, ascending: ascending,
                            folderPath: folderPath, to: url, format: format, isCancelled: { cancellation.isCancelled })
                    }
                    return try CatalogIO.exportRows(records, to: url, format: format, isCancelled: { cancellation.isCancelled })
                }.value
                isWorking = false; dismiss()
            } catch {
                isWorking = false
                // Only the thrown actual parser/filesystem error is displayed.
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
        }
    }
}
