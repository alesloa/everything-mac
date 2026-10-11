import Foundation

extension QueryEngine {
    func sortedSuffix(_ ids: [UInt32], by key: SortKey, ascending: Bool, limit: Int,
                      in store: FileStore, isCancelled: @Sendable () -> Bool) -> [UInt32] {
        let earlier = sortLess(key, ascending: ascending, in: store)
        return boundedResultPrefix(ids, limit: limit, isCancelled: isCancelled) { earlier($1, $0) }.reversed()
    }

    func rankedSuffix(_ matches: [SearchMatch], limit: Int, bestFirst: Bool, in store: FileStore,
                      isCancelled: @Sendable () -> Bool) -> [UInt32] {
        func earlier(_ a: SearchMatch, _ b: SearchMatch) -> Bool {
            if a.score != b.score { return bestFirst ? a.score > b.score : a.score < b.score }
            if store.nameSortsBefore(a.id, b.id) { return true }
            if store.nameSortsBefore(b.id, a.id) { return false }
            return a.id < b.id
        }
        return boundedResultPrefix(matches, limit: limit, isCancelled: isCancelled) { earlier($1, $0) }
            .reversed().map(\.id)
    }
}

/// A suffix reverses the complete comparator, including ID ties. Merely flipping
/// ascending would choose different duplicate-name/size/date rows at the boundary.
private func boundedResultPrefix<Value>(_ values: [Value], limit: Int, isCancelled: @Sendable () -> Bool,
                                        by earlier: (Value, Value) -> Bool) -> [Value] {
    guard limit > 0, !isCancelled() else { return [] }
    var heap: [Value] = []; heap.reserveCapacity(min(limit, values.count))
    for (offset, value) in values.enumerated() {
        if offset & 1023 == 0 && isCancelled() { return [] }
        if heap.count < limit {
            heap.append(value)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard earlier(heap[parent], heap[child]) else { break }
                heap.swapAt(parent, child); child = parent
            }
        } else if earlier(value, heap[0]) {
            heap[0] = value
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
    let result = cancellableSorted(heap, isCancelled: isCancelled, by: earlier)
    return isCancelled() ? [] : result
}
