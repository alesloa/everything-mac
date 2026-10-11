import AppKit
import IndexCore

extension ResultsTable.Coordinator {
    static func sameRows(_ lhs: [FileRecord], _ rhs: [FileRecord]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy {
            SelectionIdentity($0.0) == SelectionIdentity($0.1)
                && $0.0.size == $0.1.size && $0.0.mtime == $0.1.mtime
                && $0.0.isDir == $0.1.isDir && $0.0.parent == $0.1.parent
        }
    }

    func prepareHighlights() {
        highlightPrepared = true
        highlightTask?.cancel()
        highlights = [:]
        let indexes = visibleRowIndexes()
        let rows = indexes.isEmpty ? Array(parent.rows.prefix(256)) : indexes.compactMap { record(at: $0) }
        let list = parent.resultList
        Task { [weak self] in
            guard let self, self.parent.resultList === list else { return }
            self.parent.onVisibleRows?(rows)
        }
        guard let query = parent.query, !query.text.isEmpty else { return }
        let request = UUID()
        highlightRequest = request
        highlightTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                let highlighter = QueryHighlighter(query: query)
                var result: [SelectionIdentity: RecordHighlights] = [:]
                for record in rows {
                    guard !Task.isCancelled else { return result }
                    result[SelectionIdentity(record)] = highlighter.highlights(for: record, isCancelled: { Task.isCancelled })
                }
                return result
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.highlightRequest == request else { return }
            self.highlights = result
            // Repaint without reloading rows or changing the selected identities.
            if let table = self.table {
                let repaint = indexes.isEmpty ? IndexSet(integersIn: 0..<min(256, self.rowCount)) : indexes
                table.reloadData(forRowIndexes: repaint,
                                 columnIndexes: IndexSet(integersIn: 0..<table.tableColumns.count))
            }
        }
    }

    func applyText(_ value: String, ranges: [NSRange], to field: NSTextField?) {
        let text = NSMutableAttributedString(string: value, attributes: [.foregroundColor: NSColor.labelColor])
        for range in ranges where range.location >= 0 && range.length > 0 && NSMaxRange(range) <= text.length {
            text.addAttributes([.backgroundColor: NSColor.findHighlightColor,
                                .foregroundColor: NSColor.black], range: range)
        }
        field?.attributedStringValue = text
    }
}
