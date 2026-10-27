import Foundation

public struct QueryEngine: Sendable {
    public init() {}

    // Pre-classified term: ASCII bytes (fast path) or String fallback.
    private enum TermMatcher: Sendable {
        case ascii([UInt8])   // ASCII pattern bytes, lowercased unless case-sensitive
        case string(String)   // original term, for non-ASCII fallback
    }

    // Full scans return matching ids in ascending order; restricted scans retain
    // candidate order. All terms must match (AND).
    // The substring/glob scan is the hot path; "Match whole word" is layered on top as
    // a cheap refinement pass over the already-narrowed result set, so the inner scan
    // loops stay exactly as fast as before and pay nothing when the option is off.
    public func search(_ query: Query, in store: FileStore,
                       candidates: [UInt32]? = nil,
                       isCancelled: @escaping @Sendable () -> Bool = { false }) -> [UInt32] {
        if isCancelled() { return [] }
        if query.usesAdvancedEngine {
            return advancedMatches(query, in: store, candidates: candidates, isCancelled: isCancelled).map(\.id)
        }
        if query.hasFuzzyTerms { return matches(query, in: store, candidates: candidates, isCancelled: isCancelled).map(\.id) }
        let ids = rawSearch(query, in: store, candidates: candidates, isCancelled: isCancelled)
        guard !isCancelled() else { return [] }
        guard query.wholeWord else { return ids }
        var refined: [UInt32] = []
        for id in ids {
            if isCancelled() { return [] }
            if wholeWordMatch(query, id: id, in: store) { refined.append(id) }
        }
        return isCancelled() ? [] : refined
    }

    // Every plain (non-wildcard) term must occur as a whole word in the candidate's
    // name (or full path, when matching paths). Wildcard terms already matched via the
    // glob scan and aren't constrained further — "whole word" has no meaning for them.
    private func wholeWordMatch(_ query: Query, id: UInt32, in store: FileStore) -> Bool {
        let text = query.matchPath ? store.path(of: id) : store.name(of: id)
        for term in query.terms where !(term.contains("*") || term.contains("?")) {
            if !Glob.containsWholeWord(term, in: text, caseInsensitive: query.caseInsensitive) { return false }
        }
        return true
    }

    // For large stores the scan is split across cores — a per-keystroke linear scan
    // of millions of records is the floor for substring search, so parallelizing it
    // is what keeps typing instant.
    private func rawSearch(_ query: Query, in store: FileStore,
                           candidates: [UInt32]?,
                           isCancelled: @escaping @Sendable () -> Bool) -> [UInt32] {
        let terms = query.terms
        let n = candidates?.count ?? store.count
        // Empty query = every record. With no tombstones the id range IS the answer
        // (instant). With deletions, one reserved single-threaded pass dropping dead
        // ids — faster than the chunked scan here, whose per-chunk arrays + flatMap
        // merge cost more than the scan for an all-match result.
        if terms.isEmpty {
            if let candidates {
                var out: [UInt32] = []
                out.reserveCapacity(candidates.count)
                for (i, id) in candidates.enumerated() {
                    if i & 1023 == 0 && isCancelled() { return [] }
                    if Int(id) < store.count && store.isLive(id) { out.append(id) }
                }
                return isCancelled() ? [] : out
            }
            if !store.hasDeletions { return Array(0..<UInt32(n)) }
            var out = [UInt32](); out.reserveCapacity(n)
            var id: UInt32 = 0
            let upper = UInt32(n)
            while id < upper {
                if id & 1023 == 0 && isCancelled() { return [] }
                if store.isLive(id) { out.append(id) }; id &+= 1
            }
            return out
        }

        let matchers: [TermMatcher] = terms.map { term in
            Glob.asciiBytes(term, caseInsensitive: query.caseInsensitive).map { .ascii($0) } ?? .string(term)
        }
        let ci = query.caseInsensitive
        let matchPath = query.matchPath
        let hasNonASCII = matchers.contains { if case .string = $0 { return true }; return false }

        // Serial below this threshold — thread fan-out isn't worth it for small stores.
        if n < 100_000 {
            if let candidates {
                return scanCandidates(candidates[...], matchers: matchers, matchPath: matchPath,
                                      ci: ci, in: store, isCancelled: isCancelled)
            }
            return scanRange(0, UInt32(n), matchers: matchers, matchPath: matchPath,
                             hasNonASCII: hasNonASCII, ci: ci, in: store, isCancelled: isCancelled)
        }

        // Parallel: each chunk scans a contiguous id range with the same inlined
        // loop; results are concatenated in chunk order so output stays id-ascending.
        // `store` crosses the boundary once per chunk (not per record), so the hot
        // loop stays inlinable and ARC-free per id.
        let chunks = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        let span = (n + chunks - 1) / chunks
        let parts = SearchParts<UInt32>(count: chunks)
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let lo = c * span
            let hi = min(n, lo + span)
            guard lo < hi else { return }
            if let candidates {
                parts.set(self.scanCandidates(candidates[lo..<hi], matchers: matchers,
                                              matchPath: matchPath, ci: ci, in: store,
                                              isCancelled: isCancelled), at: c)
                return
            }
            parts.set(self.scanRange(UInt32(lo), UInt32(hi), matchers: matchers,
                                    matchPath: matchPath, hasNonASCII: hasNonASCII, ci: ci,
                                    in: store, isCancelled: isCancelled), at: c)
        }
        return isCancelled() ? [] : parts.joined()
    }

    // Candidate IDs retain their original scan order. Borrow the arena for the
    // whole chunk, just as the full scan does; no per-name buffer allocation.
    private func scanCandidates(_ ids: ArraySlice<UInt32>, matchers: [TermMatcher],
                                matchPath: Bool, ci: Bool, in store: FileStore,
                                isCancelled: @Sendable () -> Bool) -> [UInt32] {
        store.withNameArena { arena in
            var out: [UInt32] = []
            for (i, id) in ids.enumerated() {
                if i & 1023 == 0 && isCancelled() { return [] }
                guard Int(id) < store.count, store.isLive(id) else { continue }
                var string = matchPath ? store.path(of: id) : nil
                func matches(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
                    for matcher in matchers {
                        switch matcher {
                        case .ascii(let pattern):
                            guard Glob.matchesASCII(pattern, in: bytes, caseInsensitive: ci) else { return false }
                        case .string(let term):
                            if string == nil { string = store.name(of: id) }
                            guard Glob.matches(pattern: term, in: string!, caseInsensitive: ci) else { return false }
                        }
                    }
                    return true
                }
                let matched: Bool
                if let path = string {
                    matched = Array(path.utf8).withUnsafeBufferPointer { matches($0) }
                } else {
                    matched = matches(arena.bytes(in: store.nameRange(of: id)))
                }
                if matched { out.append(id) }
            }
            return isCancelled() ? [] : out
        }
    }

    // Scan ids in [lo, hi) and return those matching every term. The match logic is
    // inlined in three specialized loops (path / mixed-non-ASCII / all-ASCII) so the
    // common all-ASCII name scan allocates nothing and the optimizer can inline the
    // byte matcher. Called once per chunk — `store` is borrowed for the whole range.
    private func scanRange(_ lo: UInt32, _ hi: UInt32, matchers: [TermMatcher],
                           matchPath: Bool, hasNonASCII: Bool, ci: Bool, in store: FileStore,
                           isCancelled: @Sendable () -> Bool) -> [UInt32] {
        store.withNameArena { arena in
            var out: [UInt32] = []
            out.reserveCapacity(Int(hi - lo) / 64 + 16)

            // Whether any record is tombstoned. If not, skip the per-id live check
            // entirely (the common case — keeps the hot all-ASCII loop branch-free).
            let checkLive = store.hasDeletions

            if matchPath {
                var id = lo
                while id < hi {
                    if id & 1023 == 0 && isCancelled() { return [] }
                    if checkLive && !store.isLive(id) { id &+= 1; continue }
                    let pathStr = store.path(of: id)
                    var all = true
                    for m in matchers {
                        switch m {
                        case .ascii(let pat):
                            if !Glob.matchesASCII(pat, in: Array(pathStr.utf8)[...], caseInsensitive: ci) { all = false }
                        case .string(let term):
                            if !Glob.matches(pattern: term, in: pathStr, caseInsensitive: ci) { all = false }
                        }
                        if !all { break }
                    }
                    if all { out.append(id) }
                    id &+= 1
                }
            } else if hasNonASCII {
                var id = lo
                while id < hi {
                    if id & 1023 == 0 && isCancelled() { return [] }
                    if checkLive && !store.isLive(id) { id &+= 1; continue }
                    let nameSlice = arena.bytes(in: store.nameRange(of: id))
                    var all = true
                    var nameStr: String? = nil
                    for m in matchers {
                        switch m {
                        case .ascii(let pat):
                            if !Glob.matchesASCII(pat, in: nameSlice, caseInsensitive: ci) { all = false }
                        case .string(let term):
                            if nameStr == nil { nameStr = store.name(of: id) }
                            if !Glob.matches(pattern: term, in: nameStr!, caseInsensitive: ci) { all = false }
                        }
                        if !all { break }
                    }
                    if all { out.append(id) }
                    id &+= 1
                }
            } else {
                // Common case: all terms ASCII — zero String allocation per record.
                var id = lo
                while id < hi {
                    if id & 1023 == 0 && isCancelled() { return [] }
                    if checkLive && !store.isLive(id) { id &+= 1; continue }
                    let nameSlice = arena.bytes(in: store.nameRange(of: id))
                    var all = true
                    for m in matchers {
                        if case .ascii(let pat) = m, !Glob.matchesASCII(pat, in: nameSlice, caseInsensitive: ci) {
                            all = false; break
                        }
                    }
                    if all { out.append(id) }
                    id &+= 1
                }
            }
            return out
        }
    }
}

// Borrow a name's byte range without creating a reference-counted ArraySlice.
private extension UnsafeBufferPointer where Element == UInt8 {
    func bytes(in range: Range<Int>) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: baseAddress?.advanced(by: range.lowerBound), count: range.count)
    }
}

public extension QueryEngine {
    enum SortKey: Sendable { case relevance, name, path, size, mtime, kind }

    // `a` ranks before `b` in ASCENDING order for the given key. Name uses the
    // allocation-free byte comparator; path falls back to a String compare (rare,
    // user-selected column). size/mtime are plain integer compares.
    private func ascendingLess(_ key: SortKey, in store: FileStore) -> (UInt32, UInt32) -> Bool {
        switch key {
        case .relevance, .name: return { store.nameSortsBefore($0, $1) }
        case .path:  return { store.path(of: $0).localizedStandardCompare(store.path(of: $1)) == .orderedAscending }
        case .size:  return { store.size(of: $0) < store.size(of: $1) }
        case .mtime: return { store.mtime(of: $0) < store.mtime(of: $1) }
        case .kind:  return { store.kindSortsBefore($0, $1) }
        }
    }

    func sort(_ ids: [UInt32], by key: SortKey, ascending: Bool, in store: FileStore) -> [UInt32] {
        ids.sorted(by: sortLess(key, ascending: ascending, in: store))
    }

    func sortLess(_ key: SortKey, ascending: Bool, in store: FileStore) -> (UInt32, UInt32) -> Bool {
        let primary = ascendingLess(key, in: store)
        return { a, b in
            if primary(a, b) { return ascending }
            if primary(b, a) { return !ascending }
            // Stable record-ID ties make a bounded heap select the same rows as
            // a complete sort, including duplicate sizes, timestamps and names.
            return a < b
        }
    }

    /// Return at most `limit` ids in sorted order without fully sorting `ids`.
    /// Keeps the best `limit` via a bounded max-heap (worst-ranked on top), so the
    /// cost is O(n · log limit) instead of O(n · log n). With millions of matches
    /// for a short prefix, full-sorting every keystroke is what made typing lag;
    /// since the UI only ever shows `limit` rows, the rest never needs ordering.
    func sortedPrefix(_ ids: [UInt32], by key: SortKey, ascending: Bool,
                      limit: Int, in store: FileStore,
                      isCancelled: @Sendable () -> Bool = { false }) -> [UInt32] {
        guard limit > 0, !isCancelled() else { return [] }
        let earlier = sortLess(key, ascending: ascending, in: store)

        if ids.count <= limit {
            let result = cancellableSorted(ids, isCancelled: isCancelled, by: earlier)
            return isCancelled() ? [] : result
        }

        // Max-heap keyed by "worse rank" — the element most likely to be evicted
        // sits at the root. `worse(x, y)` is true when x ranks AFTER y.
        func worse(_ x: UInt32, _ y: UInt32) -> Bool { earlier(y, x) }
        var heap: [UInt32] = []
        heap.reserveCapacity(limit)

        func siftUp(_ start: Int) {
            var i = start
            while i > 0 {
                let parent = (i - 1) / 2
                if worse(heap[i], heap[parent]) { heap.swapAt(i, parent); i = parent } else { break }
            }
        }
        func siftDown(_ start: Int) {
            var i = start
            let n = heap.count
            while true {
                let l = 2 * i + 1, r = 2 * i + 2
                var m = i
                if l < n && worse(heap[l], heap[m]) { m = l }
                if r < n && worse(heap[r], heap[m]) { m = r }
                if m == i { break }
                heap.swapAt(i, m); i = m
            }
        }

        for (i, id) in ids.enumerated() {
            if i & 1023 == 0 && isCancelled() { return [] }
            if heap.count < limit {
                heap.append(id); siftUp(heap.count - 1)
            } else if earlier(id, heap[0]) {   // better than the worst kept → replace it
                heap[0] = id; siftDown(0)
            }
        }
        let result = heap.sorted(by: earlier)
        return isCancelled() ? [] : result
    }
}
