import Foundation

/// A complete query's row addresses, with file metadata decoded only on demand.
/// The first sorted prefix is ready immediately; scrolling beyond it prepares
/// the remaining order off the UI thread without another filesystem search.
public final class SearchResultList: @unchecked Sendable {
    public let id = UUID()
    public let snapshotID: UUID
    public let count: Int
    private let store: FileStore
    private let initialIDs: [UInt32]
    private let matchingIDs: [UInt32]
    private let ordering: @Sendable (@escaping @Sendable () -> Bool) -> [UInt32]
    private let trailing: @Sendable (@escaping @Sendable () -> Bool) -> [UInt32]
    private let lock = NSLock()
    private let cancellation = SearchCancellation()
    private var orderedIDs: [UInt32]?
    private var preparation: Task<[UInt32], Never>?
    private var tailIDs: [UInt32] = []
    private var tailPreparation: Task<[UInt32], Never>?

    init(store: FileStore, snapshotID: UUID, matchingIDs: [UInt32], initialIDs: [UInt32],
         ordering: @escaping @Sendable (@escaping @Sendable () -> Bool) -> [UInt32],
         trailing: @escaping @Sendable (@escaping @Sendable () -> Bool) -> [UInt32]) {
        self.store = store; self.snapshotID = snapshotID
        self.matchingIDs = matchingIDs; self.initialIDs = initialIDs
        self.count = matchingIDs.count; self.ordering = ordering; self.trailing = trailing
        if initialIDs.count == count { orderedIDs = initialIDs }
    }

    deinit { cancel() }

    public var isPrepared: Bool { lock.withLock { orderedIDs != nil } }
    public var hasStartedOrdering: Bool { lock.withLock { preparation != nil || orderedIDs != nil } }

    /// Explicit actions retain the snapshot with an independent ordering lifetime.
    /// Replacing the visible query can cancel its work without invalidating a menu
    /// or export that already captured these rows.
    func pinned() -> SearchResultList {
        let copy = SearchResultList(store: store, snapshotID: snapshotID, matchingIDs: matchingIDs,
                                    initialIDs: initialIDs, ordering: ordering, trailing: trailing)
        copy.orderedIDs = lock.withLock { orderedIDs }
        copy.tailIDs = lock.withLock { tailIDs }
        return copy
    }

    func selectedIDs(_ rows: IndexSet) async -> [UInt32] {
        if rows.count == count, rows.first == 0, rows.last == count - 1 { return matchingIDs }
        let ready = lock.withLock { (orderedIDs, tailIDs) }
        let available: [UInt32]? = {
            var result: [UInt32] = []
            for (offset, row) in rows.enumerated() {
                if offset & 1023 == 0 && Task.isCancelled { return nil }
                if let orderedIDs = ready.0 { result.append(orderedIDs[row]) }
                else if row < initialIDs.count { result.append(initialIDs[row]) }
                else if row >= count - ready.1.count { result.append(ready.1[row - count + ready.1.count]) }
                else { return nil }
            }
            return result
        }()
        if let available { return available }
        guard await prepare() else { return [] }
        let ids = lock.withLock { orderedIDs ?? [] }
        var result: [UInt32] = []; result.reserveCapacity(rows.count)
        for (offset, row) in rows.enumerated() {
            if offset & 1023 == 0 && Task.isCancelled { return [] }
            if ids.indices.contains(row) { result.append(ids[row]) }
        }
        return result
    }

    func remap(_ selection: SearchRowSelection) async -> SearchRowSelection? {
        let selected = await selection.list.selectedIDs(selection.rows)
        guard !selected.isEmpty, !Task.isCancelled else { return nil }
        if selected.count <= 32 {
            let records = selected.map { selection.list.record($0) }
            let retained = await retaining(records)
            let rows = await indexes(of: retained)
            return rows.isEmpty ? nil : SearchRowSelection(list: self, rows: IndexSet(rows))
        }
        guard await prepare() else { return nil }
        let ids = lock.withLock { orderedIDs ?? [] }, old = selection.list.store, store = store
        let worker = Task.detached(priority: .userInitiated) {
            var bits = [UInt64](repeating: 0, count: (old.count + 63) / 64)
            for (offset, id) in selected.enumerated() {
                if offset & 1023 == 0 && Task.isCancelled { return IndexSet() }
                bits[Int(id) / 64] |= 1 << (Int(id) % 64)
            }
            let stable = store.sharesSlots(with: old)
            var rows = IndexSet(), start: Int?
            for (row, id) in ids.enumerated() {
                if row & 1023 == 0 && Task.isCancelled { return IndexSet() }
                let matched = Int(id) < old.count && bits[Int(id) / 64] & (1 << (Int(id) % 64)) != 0 &&
                    (stable || old.path(of: id).utf8.elementsEqual(store.path(of: id).utf8))
                if matched, start == nil { start = row }
                if !matched, let first = start { rows.insert(integersIn: first..<row); start = nil }
            }
            if let start { rows.insert(integersIn: start..<ids.count) }
            return rows
        }
        let rows = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        return rows.isEmpty ? nil : SearchRowSelection(list: self, rows: rows)
    }

    public func cancel() {
        cancellation.cancel()
        lock.withLock { preparation }?.cancel()
        lock.withLock { tailPreparation }?.cancel()
    }

    /// Memory-only lookup. Nil means the requested order is still being prepared.
    public func record(at row: Int) -> FileRecord? {
        guard row >= 0, row < count else { return nil }
        let slot: UInt32? = lock.withLock {
            if let orderedIDs { return orderedIDs[row] }
            if row < initialIDs.count { return initialIDs[row] }
            if row >= count - tailIDs.count { return tailIDs[row - count + tailIDs.count] }
            return nil
        }
        return slot.map(record)
    }

    /// Make the last viewport addressable with a bounded heap, independently of
    /// the full background sort. First and last pages remain consistent with it.
    @discardableResult public func prepareTail() async -> Bool {
        if lock.withLock({ orderedIDs != nil || !tailIDs.isEmpty }) { return true }
        let task = lock.withLock {
            if let tailPreparation { return tailPreparation }
            let trailing = trailing, cancellation = cancellation
            let task = Task.detached(priority: .userInitiated) {
                trailing { cancellation.isCancelled || Task.isCancelled }
            }
            tailPreparation = task; return task
        }
        let ids = await task.value
        guard !Task.isCancelled, !cancellation.isCancelled, !ids.isEmpty else { return false }
        lock.withLock { tailIDs = ids }
        return true
    }

    @discardableResult public func prepare() async -> Bool {
        if lock.withLock({ orderedIDs != nil }) { return true }
        let task = lock.withLock {
            if let preparation { return preparation }
            let ordering = ordering, cancellation = cancellation
            let task = Task.detached(priority: .userInitiated) {
                ordering { cancellation.isCancelled || Task.isCancelled }
            }
            preparation = task
            return task
        }
        let ids = await task.value
        guard !Task.isCancelled, !cancellation.isCancelled, ids.count == count else { return false }
        lock.withLock { orderedIDs = ids }
        return true
    }

    /// Resolve an existing selection against this query without decoding all rows.
    public func retaining(_ records: [FileRecord]) async -> [FileRecord] {
        guard !records.isEmpty else { return [] }
        let store = store, matchingIDs = matchingIDs
        let worker = Task.detached(priority: .userInitiated) {
            let requested = Set(records.map(\.id))
            var matched: Set<UInt32> = []
            for (offset, slot) in matchingIDs.enumerated() {
                if offset & 1023 == 0 && Task.isCancelled { return [FileRecord]() }
                if requested.contains(slot) { matched.insert(slot) }
                if matched.count == requested.count { break }
            }
            return records.compactMap { old -> FileRecord? in
                guard matched.contains(old.id), store.path(of: old.id).utf8.elementsEqual(old.path.utf8) else { return nil }
                return Self.record(old.id, in: store)
            }
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    public func indexes(of records: [FileRecord]) async -> [Int] {
        guard !records.isEmpty else { return [] }
        let initial = indexes(of: records, in: initialIDs)
        if initial.count == records.count { return initial }
        let tail = lock.withLock { tailIDs }
        let known = Array(Set(initial + indexes(of: records, in: tail).map { count - tail.count + $0 })).sorted()
        if known.count == records.count { return known }
        guard await prepare() else { return [] }
        let ids = lock.withLock { orderedIDs ?? [] }
        let worker = Task.detached(priority: .userInitiated) { [self] in indexes(of: records, in: ids) }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    private func indexes(of records: [FileRecord], in ids: [UInt32]) -> [Int] {
        let requested = Dictionary(records.map { ($0.id, $0.path) }, uniquingKeysWith: { first, _ in first })
        var result: [Int] = []
        for (row, slot) in ids.enumerated() {
            if row & 1023 == 0 && Task.isCancelled { return [] }
            if let path = requested[slot], store.path(of: slot).utf8.elementsEqual(path.utf8) {
                result.append(row)
                if result.count == requested.count { break }
            }
        }
        return result
    }

    private func record(_ slot: UInt32) -> FileRecord { Self.record(slot, in: store) }
    private static func record(_ slot: UInt32, in store: FileStore) -> FileRecord {
        FileRecord(id: slot, name: store.name(of: slot), path: store.path(of: slot),
                   parent: store.parent(of: slot), size: store.size(of: slot), mtime: store.mtime(of: slot),
                   isDir: store.isDir(of: slot), volID: store.volID(of: slot))
    }
}

func cancellableSorted<Element>(_ values: [Element], isCancelled: @Sendable () -> Bool,
                                by earlier: (Element, Element) -> Bool) -> [Element] {
    var comparisons = 0
    do {
        return try values.sorted { a, b in
            comparisons &+= 1
            if comparisons & 1023 == 0 && isCancelled() { throw CancellationError() }
            return earlier(a, b)
        }
    } catch { return [] }
}
