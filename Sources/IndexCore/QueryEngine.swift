import Foundation

public struct QueryEngine: Sendable {
    public init() {}

    // Pre-classified term: ASCII bytes (fast path) or String fallback.
    private enum TermMatcher {
        case ascii([UInt8])   // lowercased ASCII pattern bytes
        case string(String)   // original term, for non-ASCII or case-sensitive fallback
    }

    // Returns matching record ids in ascending id order. All terms must match (AND).
    // For large stores the scan is split across cores — a per-keystroke linear scan
    // of millions of records is the floor for substring search, so parallelizing it
    // is what keeps typing instant.
    public func search(_ query: Query, in store: FileStore) -> [UInt32] {
        let terms = query.terms
        let n = store.count
        // Empty query = every record. With no tombstones the id range IS the answer
        // (instant). With deletions, one reserved single-threaded pass dropping dead
        // ids — faster than the chunked scan here, whose per-chunk arrays + flatMap
        // merge cost more than the scan for an all-match result.
        if terms.isEmpty {
            if !store.hasDeletions { return Array(0..<UInt32(n)) }
            var out = [UInt32](); out.reserveCapacity(n)
            var id: UInt32 = 0
            let upper = UInt32(n)
            while id < upper { if store.isLive(id) { out.append(id) }; id &+= 1 }
            return out
        }

        let matchers: [TermMatcher] = terms.map { term in
            if query.caseInsensitive, let bytes = Glob.asciiLowerBytes(term) { return .ascii(bytes) }
            return .string(term)
        }
        let ci = query.caseInsensitive
        let matchPath = query.matchPath
        let hasNonASCII = matchers.contains { if case .string = $0 { return true }; return false }

        // Serial below this threshold — thread fan-out isn't worth it for small stores.
        if n < 100_000 {
            return scanRange(0, UInt32(n), matchers: matchers, matchPath: matchPath,
                             hasNonASCII: hasNonASCII, ci: ci, in: store)
        }

        // Parallel: each chunk scans a contiguous id range with the same inlined
        // loop; results are concatenated in chunk order so output stays id-ascending.
        // `store` crosses the boundary once per chunk (not per record), so the hot
        // loop stays inlinable and ARC-free per id.
        let chunks = max(2, ProcessInfo.processInfo.activeProcessorCount)
        let span = (n + chunks - 1) / chunks
        var parts = [[UInt32]](repeating: [], count: chunks)
        parts.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let lo = c * span
                let hi = min(n, lo + span)
                guard lo < hi else { return }
                buf[c] = self.scanRange(UInt32(lo), UInt32(hi), matchers: matchers,
                                        matchPath: matchPath, hasNonASCII: hasNonASCII, ci: ci, in: store)
            }
        }
        return parts.flatMap { $0 }
    }

    // Scan ids in [lo, hi) and return those matching every term. The match logic is
    // inlined in three specialized loops (path / mixed-non-ASCII / all-ASCII) so the
    // common all-ASCII name scan allocates nothing and the optimizer can inline the
    // byte matcher. Called once per chunk — `store` is borrowed for the whole range.
    private func scanRange(_ lo: UInt32, _ hi: UInt32, matchers: [TermMatcher],
                           matchPath: Bool, hasNonASCII: Bool, ci: Bool, in store: FileStore) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(Int(hi - lo) / 64 + 16)

        // Whether any record is tombstoned. If not, skip the per-id live check
        // entirely (the common case — keeps the hot all-ASCII loop branch-free).
        let checkLive = store.hasDeletions

        if matchPath {
            var id = lo
            while id < hi {
                if checkLive && !store.isLive(id) { id &+= 1; continue }
                let pathStr = store.path(of: id)
                var all = true
                for m in matchers {
                    switch m {
                    case .ascii(let pat):
                        if !Glob.matchesASCII(patternLowerBytes: pat, in: Array(pathStr.utf8)[...]) { all = false }
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
                if checkLive && !store.isLive(id) { id &+= 1; continue }
                let nameSlice = store.nameBytesSlice(of: id)
                var all = true
                var nameStr: String? = nil
                for m in matchers {
                    switch m {
                    case .ascii(let pat):
                        if !Glob.matchesASCII(patternLowerBytes: pat, in: nameSlice) { all = false }
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
                if checkLive && !store.isLive(id) { id &+= 1; continue }
                let nameSlice = store.nameBytesSlice(of: id)
                var all = true
                for m in matchers {
                    if case .ascii(let pat) = m, !Glob.matchesASCII(patternLowerBytes: pat, in: nameSlice) {
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

public extension QueryEngine {
    enum SortKey: Sendable { case name, path, size, mtime, kind }

    // `a` ranks before `b` in ASCENDING order for the given key. Name uses the
    // allocation-free byte comparator; path falls back to a String compare (rare,
    // user-selected column). size/mtime are plain integer compares.
    private func ascendingLess(_ key: SortKey, in store: FileStore) -> (UInt32, UInt32) -> Bool {
        switch key {
        case .name:  return { store.nameSortsBefore($0, $1) }
        case .path:  return { store.path(of: $0).localizedStandardCompare(store.path(of: $1)) == .orderedAscending }
        case .size:  return { store.size(of: $0) < store.size(of: $1) }
        case .mtime: return { store.mtime(of: $0) < store.mtime(of: $1) }
        case .kind:  return { store.kindSortsBefore($0, $1) }
        }
    }

    func sort(_ ids: [UInt32], by key: SortKey, ascending: Bool, in store: FileStore) -> [UInt32] {
        let asc = ascendingLess(key, in: store)
        let less: (UInt32, UInt32) -> Bool = ascending ? asc : { asc($1, $0) }
        return ids.sorted(by: less)
    }

    /// Return at most `limit` ids in sorted order without fully sorting `ids`.
    /// Keeps the best `limit` via a bounded max-heap (worst-ranked on top), so the
    /// cost is O(n · log limit) instead of O(n · log n). With millions of matches
    /// for a short prefix, full-sorting every keystroke is what made typing lag;
    /// since the UI only ever shows `limit` rows, the rest never needs ordering.
    func sortedPrefix(_ ids: [UInt32], by key: SortKey, ascending: Bool,
                      limit: Int, in store: FileStore) -> [UInt32] {
        let asc = ascendingLess(key, in: store)
        let earlier: (UInt32, UInt32) -> Bool = ascending ? asc : { asc($1, $0) }

        if ids.count <= limit { return ids.sorted(by: earlier) }

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

        for id in ids {
            if heap.count < limit {
                heap.append(id); siftUp(heap.count - 1)
            } else if earlier(id, heap[0]) {   // better than the worst kept → replace it
                heap[0] = id; siftDown(0)
            }
        }
        return heap.sorted(by: earlier)
    }
}
