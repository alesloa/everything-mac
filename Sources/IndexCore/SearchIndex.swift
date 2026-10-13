import Foundation

// The writer publishes immutable FileStore values. Locking only copies/swaps a
// snapshot reference; filesystem IO, copying mutated arrays, searching and sorting
// all happen outside the lock. Swift's copy-on-write arrays preserve old searches.
public final class SearchIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Snapshot(store: FileStore())

    public init() {}
    deinit { current.cancelFolderPreparation() }

    public func publish(_ store: FileStore) {
        let next = Snapshot(store: store.searchSnapshot())
        let previous = lock.withLock {
            let previous = current
            current = next
            return previous
        }
        // Releasing a large old store/query cache must not hold the reader lock.
        previous.cancelFolderPreparation()
        withExtendedLifetime(previous) {}
    }

    public var count: Int {
        let snapshot = lock.withLock { current }
        return snapshot.store.count - snapshot.store.deletedCount
    }

    /// Capture the immutable published value for background streaming exports.
    /// Copy-on-write storage keeps later live updates out of this snapshot.
    public func readSnapshot() -> FileStore { lock.withLock { current.store } }

    public func path(of id: UInt32) -> String? {
        let snapshot = lock.withLock { current }
        guard Int(id) < snapshot.store.count, snapshot.store.isLive(id) else { return nil }
        return snapshot.store.path(of: id)
    }

    public func search(_ query: Query, sort: QueryEngine.SortKey = .relevance,
                       ascending: Bool = true, limit: Int = 5000) async -> [FileRecord] {
        guard limit > 0 else { return [] }
        return await searchReport(query, sort: sort, ascending: ascending, limit: limit).records
    }

    public func searchReport(_ query: Query, sort: QueryEngine.SortKey = .relevance,
                             ascending: Bool = true, limit: Int = 5000,
                             scope: FolderScope? = nil, folderSelection: FolderSearchScope? = nil,
                             includeAllResults: Bool = false) async -> SearchReport {
        let query = query.refreshingRelativeDates()
        let snapshot = lock.withLock { current }
        let cancellation = SearchCancellation()
        return await withTaskCancellationHandler {
            let worker = Task.detached(priority: .userInitiated) {
                snapshot.search(query, sort: sort, ascending: ascending, limit: limit, scope: scope,
                                folderSelection: folderSelection,
                                includeAllResults: includeAllResults,
                                isCancelled: { cancellation.isCancelled })
            }
            return await worker.value
        } onCancel: { cancellation.cancel() }
    }

    public func folderSnapshot() async -> FolderSnapshot? {
        let snapshot = lock.withLock { current }
        let result = await snapshot.folders().value
        return Task.isCancelled ? nil : result
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
        let id = UUID()
        private let cacheLock = NSLock()
        private var cached: (Query, Matches)?
        private var cachedScope: (FolderSearchScope, ResolvedFolderSearchScope)?
        private var nameIndex: UniqueNameIndex?
        private let namePreparation: UniqueNameIndex.Preparation
        private var folderTask: Task<FolderSnapshot?, Never>?
        private let folderCancellation = SearchCancellation()
        init(store: FileStore) {
            self.store = store
            namePreparation = UniqueNameIndex.Preparation(store: store)
        }

        func folders() -> Task<FolderSnapshot?, Never> {
            cacheLock.withLock {
                if let folderTask { return folderTask }
                let store = store, id = id, cancellation = folderCancellation
                let task = Task.detached(priority: .utility) {
                    FolderSnapshot.build(store: store, snapshotID: id,
                                         isCancelled: { cancellation.isCancelled || Task.isCancelled })
                }
                folderTask = task
                return task
            }
        }

        func cancelFolderPreparation() {
            folderCancellation.cancel()
            cacheLock.withLock { folderTask }?.cancel()
        }

        private func names() -> UniqueNameIndex? {
            if let ready = cacheLock.withLock({ nameIndex }) { return ready }
            // Ready-only lookup: cold preparation never lands on a typed query.
            guard let built = namePreparation.ready() else { return nil }
            return cacheLock.withLock {
                if let ready = nameIndex { return ready }
                nameIndex = built
                return built
            }
        }

        func search(_ query: Query, sort: QueryEngine.SortKey, ascending: Bool, limit: Int,
                    scope: FolderScope?, folderSelection: FolderSearchScope?, includeAllResults: Bool,
                    isCancelled: @escaping @Sendable () -> Bool) -> SearchReport {
            let empty = SearchReport(records: [], totalMatches: 0, snapshotID: id, revision: store.revision)
            guard !isCancelled() else { return empty }
            let engine = QueryEngine()
            let previous = cacheLock.withLock { cached }
            let matches: Matches
            if let previous, previous.0 == query {
                matches = previous.1
            } else {
                // Cache complete matches, never the displayed top rows. Restrict
                // only a provably narrower query, and recompute every fuzzy score.
                let candidates = previous.flatMap { query.narrows($0.0) ? $0.1.ids : nil }
                let names = candidates != nil || query.matchPath || query.terms.isEmpty ? nil : names()
                guard !isCancelled() else { return empty }
                matches = query.hasFuzzyTerms
                    ? .fuzzy(engine.matches(query, in: store, candidates: candidates,
                                            nameIndex: names, isCancelled: isCancelled))
                    : .exact(engine.search(query, in: store, candidates: candidates,
                                           nameIndex: names, isCancelled: isCancelled))
                guard !isCancelled() else { return empty }
                let old = cacheLock.withLock {
                    let old = cached
                    cached = (query, matches)
                    return old
                }
                withExtendedLifetime(old) {}
            }
            let displayedMatches: Matches
            if let selection = folderSelection ?? scope.map({ FolderSearchScope(included: [$0]) }) {
                let resolved: ResolvedFolderSearchScope
                if let cached = cacheLock.withLock({ cachedScope }), cached.0 == selection { resolved = cached.1 }
                else {
                    guard let prepared = try? ResolvedFolderSearchScope(selection, in: store, isCancelled: isCancelled) else { return empty }
                    resolved = prepared
                    cacheLock.withLock { cachedScope = (selection, resolved) }
                }
                // Scope is applied after the cached query: changing the sidebar
                // never invalidates or repeats an ordinary full-index scan.
                switch matches {
                case .exact(let ids):
                    guard let filtered = try? resolved.filter(ids, id: { $0 }, in: store, isCancelled: isCancelled) else { return empty }
                    displayedMatches = .exact(filtered)
                case .fuzzy(let scored):
                    guard let filtered = try? resolved.filter(scored, id: { $0.id }, in: store, isCancelled: isCancelled) else { return empty }
                    displayedMatches = .fuzzy(filtered)
                }
            } else { displayedMatches = matches }
            let totalMatches: Int
            switch displayedMatches {
            case .exact(let ids): totalMatches = ids.count
            case .fuzzy(let scored): totalMatches = scored.count
            }
            let sorted: [UInt32]
            switch displayedMatches {
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
                if isCancelled() { return empty }
                records.append(FileRecord(id: id, name: store.name(of: id), path: store.path(of: id),
                                          parent: store.parent(of: id), size: store.size(of: id),
                                          mtime: store.mtime(of: id), isDir: store.isDir(of: id),
                                          volID: store.volID(of: id)))
            }
            let list = includeAllResults ? SearchResultList(store: store, snapshotID: id,
                matchingIDs: displayedMatches.ids, initialIDs: sorted, ordering: { [store] cancelled in
                    switch displayedMatches {
                    case .fuzzy(let scored) where sort == .relevance:
                        return engine.rankedPrefix(scored, limit: totalMatches, bestFirst: ascending,
                                                   in: store, isCancelled: cancelled)
                    case .fuzzy(let scored):
                        return engine.sortedPrefix(scored.map(\.id), by: sort, ascending: ascending,
                                                   limit: totalMatches, in: store, isCancelled: cancelled)
                    case .exact(let ids):
                        return engine.sortedPrefix(ids, by: sort, ascending: ascending,
                                                   limit: totalMatches, in: store, isCancelled: cancelled)
                    }
                }, trailing: { [store] cancelled in
                    switch displayedMatches {
                    case .fuzzy(let scored) where sort == .relevance:
                        return engine.rankedSuffix(scored, limit: 512, bestFirst: ascending, in: store, isCancelled: cancelled)
                    case .fuzzy(let scored):
                        return engine.sortedSuffix(scored.map(\.id), by: sort, ascending: ascending,
                                                   limit: 512, in: store, isCancelled: cancelled)
                    case .exact(let ids):
                        return engine.sortedSuffix(ids, by: sort, ascending: ascending,
                                                   limit: 512, in: store, isCancelled: cancelled)
                    }
                }) : nil
            return SearchReport(records: records, totalMatches: totalMatches,
                                snapshotID: id, revision: store.revision, resultList: list)
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

    @discardableResult
    public func save(_ store: FileStore, to url: URL, lastEventID: UInt64,
                     rulesFingerprint: UInt64, revision: UInt64) throws -> Bool {
        guard revision > savedRevision else { return false }
        try IndexCache.save(store, to: url, lastEventID: lastEventID, rulesFingerprint: rulesFingerprint)
        savedRevision = revision
        return true
    }
}
