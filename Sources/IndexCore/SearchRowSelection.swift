import Foundation

/// Keeps the complete selection as compact row ranges, without allocating paths.
public struct SearchRowSelection: Sendable {
    public let list: SearchResultList
    public let rows: IndexSet
    public var count: Int { rows.count }

    public init(list: SearchResultList, rows: IndexSet) {
        self.list = list
        self.rows = rows.intersection(IndexSet(integersIn: 0..<list.count))
    }

    /// Only the small preview sample is decoded during ordinary UI selection.
    public var preview: [FileRecord] { rows.prefix(32).compactMap { list.record(at: $0) } }

    public func retaining(in next: SearchResultList) async -> SearchRowSelection? { await next.remap(self) }

    public func pinned() -> SearchRowSelection { SearchRowSelection(list: list.pinned(), rows: rows) }

    /// Explicit actions resolve every selected row off the main thread.
    public func records() async -> [FileRecord] {
        let list = list.pinned(), rows = rows
        let ready = await withTaskCancellationHandler { await list.prepare() } onCancel: { list.cancel() }
        guard ready, !Task.isCancelled else { return [] }
        let worker = Task.detached(priority: .userInitiated) {
            var records: [FileRecord] = []; records.reserveCapacity(rows.count)
            for (offset, row) in rows.enumerated() {
                if offset & 255 == 0 && Task.isCancelled { return [FileRecord]() }
                guard let record = list.record(at: row) else { return [FileRecord]() }
                records.append(record)
            }
            return records
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }
}
