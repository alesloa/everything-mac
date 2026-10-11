import Foundation

// The writer publishes immutable FileStore values. Locking only copies/swaps a
// snapshot reference; filesystem IO, copying mutated arrays, searching and sorting
// all happen outside the lock. Swift's copy-on-write arrays preserve old searches.
public final class SearchIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Snapshot(store: FileStore())

    public init() {}

    public func publish(_ store: FileStore) {
        let next = Snapshot(store: store.searchSnapshot())
        let previous = lock.withLock {
            let previous = current
            current = next
            return previous
        }
        // Releasing a large old store/query cache must not hold the reader lock.
        withExtendedLifetime(previous) {}
    }

    public var count: Int {
        let snapshot = lock.withLock { current }
        return snapshot.store.count - snapshot.store.deletedCount
    }

    public func path(of id: UInt32) -> String? {
        let snapshot = lock.withLock { current }
        guard Int(id) < snapshot.store.count, snapshot.store.isLive(id) else { return nil }
        return snapshot.store.path(of: id)
    }

    public func search(_ query: Query, sort: QueryEngine.SortKey = .relevance,
                       ascending: Bool = true, limit: Int = 5000) async -> [FileRecord] {
        let snapshot = lock.withLock { current }
        let cancellation = SearchCancellation()
        return await withTaskCancellationHandler {
            let worker = Task.detached(priority: .userInitiated) {
                snapshot.search(query, sort: sort, ascending: ascending, limit: limit,
                                isCancelled: { cancellation.isCancelled })
            }
            return await worker.value
        } onCancel: { cancellation.cancel() }
    }

    private final class Snapshot: @unchecked Sendable {
        private enum Matches: Sendable {
            case exact([UInt32])
            case fuzzy([SearchMatch])

            var ids: [UInt32] {
                switch self {
                case .exact(let ids): return ids
                case .fuzzy(let matches): return matches.map(\.id)
                }
            }
        }
        let store: FileStore
        private let cacheLock = NSLock()
        private var cached: (Query, Matches)?
        init(store: FileStore) { self.store = store }

        func search(_ query: Query, sort: QueryEngine.SortKey, ascending: Bool, limit: Int,
                    isCancelled: @escaping @Sendable () -> Bool) -> [FileRecord] {
            guard limit > 0, !isCancelled() else { return [] }
            let engine = QueryEngine()
            let previous = cacheLock.withLock { cached }
            let matches: Matches
            if let previous, previous.0 == query {
                matches = previous.1
            } else {
                // Cache complete matches, never the displayed top rows. Restrict
                // only a provably narrower query, and recompute every fuzzy score.
                let candidates = previous.flatMap { query.narrows($0.0) ? $0.1.ids : nil }
                matches = query.hasFuzzyTerms
                    ? .fuzzy(engine.matches(query, in: store, candidates: candidates, isCancelled: isCancelled))
                    : .exact(engine.search(query, in: store, candidates: candidates, isCancelled: isCancelled))
                guard !isCancelled() else { return [] }
                let old = cacheLock.withLock {
                    let old = cached
                    cached = (query, matches)
                    return old
                }
                withExtendedLifetime(old) {}
            }
            let sorted: [UInt32]
            switch matches {
            case .fuzzy(let scored) where sort == .relevance:
                sorted = engine.rankedPrefix(scored, limit: limit, bestFirst: ascending,
                                             in: store, isCancelled: isCancelled)
            case .fuzzy(let scored):
                sorted = engine.sortedPrefix(scored.map(\.id), by: sort, ascending: ascending,
                                             limit: limit, in: store, isCancelled: isCancelled)
            case .exact(let ids):
                sorted = engine.sortedPrefix(ids, by: sort, ascending: ascending,
                                             limit: limit, in: store, isCancelled: isCancelled)
            }
            var records: [FileRecord] = []
            records.reserveCapacity(sorted.count)
            for id in sorted {
                if isCancelled() { return [] }
                records.append(FileRecord(id: id, name: store.name(of: id), path: store.path(of: id),
                                          parent: store.parent(of: id), size: store.size(of: id),
                                          mtime: store.mtime(of: id), isDir: store.isDir(of: id),
                                          volID: store.volID(of: id)))
            }
            return records
        }
    }
}

final class SearchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

// A separate serial writer avoids both actor stalls and out-of-order cache saves.
public actor IndexCacheWriter {
    private var savedRevision: UInt64 = 0
    public init() {}

    public func save(_ store: FileStore, to url: URL, lastEventID: UInt64,
                     rulesFingerprint: UInt64, revision: UInt64) throws {
        guard revision > savedRevision else { return }
        try IndexCache.save(store, to: url, lastEventID: lastEventID, rulesFingerprint: rulesFingerprint)
        savedRevision = revision
    }
}
