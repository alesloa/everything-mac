import Foundation

public struct SearchMatch: Sendable, Equatable {
    public let id: UInt32
    public let score: Int
    public init(id: UInt32, score: Int) { self.id = id; self.score = score }
}

// Each parallel chunk publishes once; queries never hold this lock while scanning.
final class SearchParts<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [[T]]
    init(count: Int) { parts = Array(repeating: [], count: count) }
    func set(_ values: [T], at index: Int) { lock.withLock { parts[index] = values } }
    func joined() -> [T] { lock.withLock { parts.flatMap { $0 } } }
}

extension QueryEngine {
    private enum FuzzyTerm: Sendable {
        case ascii(FuzzyMatcher.Pattern)
        case unicode(String)
        case literal(String, [UInt8]?)

        func workerCopy() -> FuzzyTerm {
            switch self {
            case .ascii(let pattern):
                return .ascii(FuzzyMatcher.Pattern(String(decoding: pattern.bytes, as: UTF8.self),
                                                   caseInsensitive: pattern.caseInsensitive))
            case .literal(let text, let bytes): return .literal(text, bytes?.map { $0 })
            case .unicode: return self
            }
        }
    }

    public func matches(_ query: Query, in store: FileStore,
                        isCancelled: @escaping @Sendable () -> Bool = { false }) -> [SearchMatch] {
        guard query.hasFuzzyTerms else {
            return search(query, in: store, isCancelled: isCancelled).map { SearchMatch(id: $0, score: 0) }
        }
        let terms: [FuzzyTerm] = query.tokens.map { token in
            if token.isLiteral {
                return .literal(token.text, query.caseInsensitive ? Glob.asciiLowerBytes(token.text) : nil)
            }
            if token.text.utf8.allSatisfy({ $0 < 128 }) {
                return .ascii(FuzzyMatcher.Pattern(token.text, caseInsensitive: query.caseInsensitive))
            }
            return .unicode(token.text)
        }
        @Sendable func scan(_ lo: Int, _ hi: Int) -> [SearchMatch] {
            // Give each worker its own small pattern buffers too, so refcounting
            // a pattern in the hot loop cannot contend with other search threads.
            let terms = terms.map { $0.workerCopy() }
            func evaluate(_ id: UInt32, name: UnsafeBufferPointer<UInt8>, mask: UInt64, path: String?) -> Int? {
                var string = path
                var score = 0
                for term in terms {
                    switch term {
                    case .ascii(let pattern):
                        guard let value = pattern.score(name, nameMask: mask) else { return nil }
                        score += value
                    case .unicode(let pattern):
                        if string == nil { string = store.name(of: id) }
                        guard let value = FuzzyMatcher.unicodeScore(string!, pattern, ci: query.caseInsensitive) else { return nil }
                        score += value
                    case .literal(let pattern, let ascii):
                        if let ascii {
                            guard Glob.matchesASCII(patternLowerBytes: ascii, in: name) else { return nil }
                        } else {
                            if string == nil { string = store.name(of: id) }
                            guard Glob.matches(pattern: pattern, in: string!, caseInsensitive: query.caseInsensitive) else { return nil }
                        }
                    }
                }
                return score
            }
            // Borrow the name arena once per chunk. Creating an ArraySlice for
            // every record makes worker threads contend on its ARC reference count.
            return store.withNameArena { arena in
                var out: [SearchMatch] = []
                for i in lo..<hi {
                    if i & 1023 == 0 && isCancelled() { return [] }
                    let id = UInt32(i)
                    guard store.isLive(id) else { continue }
                    if query.matchPath {
                        let path = store.path(of: id)
                        let value = Array(path.utf8).withUnsafeBufferPointer { name in
                            evaluate(id, name: name, mask: FuzzyMatcher.mask(name), path: path)
                        }
                        if let value { out.append(SearchMatch(id: id, score: value)) }
                    } else {
                        let mask = store.nameMask(of: id)
                        let fits = terms.allSatisfy { term in
                            if case .ascii(let pattern) = term { return pattern.fits(mask) }
                            return true
                        }
                        guard fits else { continue }
                        let range = store.nameRange(of: id)
                        let name = arena.bytes(in: range)
                        if let value = evaluate(id, name: name, mask: mask, path: nil) {
                            out.append(SearchMatch(id: id, score: value))
                        }
                    }
                }
                return out
            }
        }
        let n = store.count
        if n < 100_000 { return isCancelled() ? [] : scan(0, n) }
        // Leave cores available for UI and filesystem work instead of saturating
        // every core with multiple superseded searches.
        let chunks = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        let span = (n + chunks - 1) / chunks
        let parts = SearchParts<SearchMatch>(count: chunks)
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let lo = c * span, hi = min(n, lo + span)
            if lo < hi { parts.set(scan(lo, hi), at: c) }
        }
        return isCancelled() ? [] : parts.joined()
    }

    // Bounded heap: score descending by default, then stable name/id ties.
    public func rankedPrefix(_ matches: [SearchMatch], limit: Int, bestFirst: Bool = true,
                             in store: FileStore,
                             isCancelled: @Sendable () -> Bool = { false }) -> [UInt32] {
        guard limit > 0 else { return [] }
        func earlier(_ a: SearchMatch, _ b: SearchMatch) -> Bool {
            if a.score != b.score { return bestFirst ? a.score > b.score : a.score < b.score }
            if store.nameSortsBefore(a.id, b.id) { return true }
            if store.nameSortsBefore(b.id, a.id) { return false }
            return a.id < b.id
        }
        var heap: [SearchMatch] = []
        heap.reserveCapacity(min(limit, matches.count))
        for (i, match) in matches.enumerated() {
            if i & 1023 == 0 && isCancelled() { return [] }
            if heap.count < limit {
                heap.append(match)
                var child = heap.count - 1
                while child > 0 {
                    let parent = (child - 1) / 2
                    guard earlier(heap[parent], heap[child]) else { break }
                    heap.swapAt(parent, child); child = parent
                }
            } else if earlier(match, heap[0]) {
                heap[0] = match
                var parent = 0
                while true {
                    let left = parent * 2 + 1, right = left + 1
                    var worst = parent
                    if left < heap.count && earlier(heap[worst], heap[left]) { worst = left }
                    if right < heap.count && earlier(heap[worst], heap[right]) { worst = right }
                    guard worst != parent else { break }
                    heap.swapAt(worst, parent); parent = worst
                }
            }
        }
        return heap.sorted(by: earlier).map(\.id)
    }
}
