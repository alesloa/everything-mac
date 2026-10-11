import Foundation

// Sort labels come from the owner's requested catalog search/sort feature.
public enum CatalogSort: String, Sendable, CaseIterable, Identifiable {
    case relevance, name, path, size, modified
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}
public enum CatalogResultID: Sendable, Hashable { case catalog(CatalogRecordID), native(UInt32, Data) }
public struct CatalogSearchHit: Sendable, Identifiable {
    public let record: CatalogRecord
    public let nativeRecord: FileRecord?
    public let score: Int
    public var id: CatalogResultID { nativeRecord.map { .native($0.id, Data($0.path.utf8)) } ?? .catalog(record.id) }
}
public struct CatalogSearchPage: Sendable {
    public let hits: [CatalogSearchHit]
    public let totalMatches: Int
}

public enum CatalogSearch {
    /// O(limit) decoded rows; the entire native/catalog source is still counted.
    /// A worst-first heap avoids sorting/materializing millions of full paths.
    public static func search(_ catalogs: [FileCatalogSnapshot], native: FileStore? = nil,
                              query: Query, sort: CatalogSort = .name, ascending: Bool = true,
                              limit: Int = 5000,
                              isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> CatalogSearchPage {
        let matcher = try CatalogQueryMatcher(query)
        var heap: [CatalogSearchHit] = [], count = 0
        let cap = max(0, limit)
        func better(_ a: CatalogSearchHit, _ b: CatalogSearchHit) -> Bool {
            func numeric<T: Comparable>(_ left: T?, _ right: T?) -> Bool? {
                if left == nil && right != nil { return false }; if left != nil && right == nil { return true }
                guard let left, let right, left != right else { return nil }
                return ascending ? left < right : left > right
            }
            var decision: Bool?
            switch sort {
            case .relevance: decision = a.score == b.score ? nil : (ascending ? a.score > b.score : a.score < b.score)
            case .size: decision = numeric(a.record.size, b.record.size)
            case .modified: decision = numeric(a.record.modified, b.record.modified)
            case .name, .path:
                let left = sort == .name ? a.nativeRecord?.name ?? a.record.name : a.record.path
                let right = sort == .name ? b.nativeRecord?.name ?? b.record.name : b.record.path
                let comparison = left.localizedStandardCompare(right)
                if comparison != .orderedSame { decision = ascending ? comparison == .orderedAscending : comparison == .orderedDescending }
            }
            if let decision { return decision }
            if a.record.path.utf8.elementsEqual(b.record.path.utf8) {
                if a.record.id.catalog == b.record.id.catalog { return a.record.id.row < b.record.id.row }
                return a.record.id.catalog.uuidString < b.record.id.catalog.uuidString
            }
            return a.record.path.utf8.lexicographicallyPrecedes(b.record.path.utf8)
        }
        func accept(_ record: CatalogRecord, native: FileRecord?, knownScore: Int? = nil) throws {
            if isCancelled() { throw CancellationError() }
            guard let score = knownScore ?? matcher.score(record, isCancelled: isCancelled) else { return }
            count += 1
            guard cap > 0 else { return }
            let hit = CatalogSearchHit(record: record, nativeRecord: native, score: score)
            if heap.count < cap {
                heap.append(hit)
                var position = heap.count - 1
                while position > 0 {
                    let parent = (position - 1) / 2
                    guard better(heap[parent], heap[position]) else { break }
                    heap.swapAt(parent, position); position = parent
                }
            } else if better(hit, heap[0]) {
                heap[0] = hit
                var position = 0
                while position * 2 + 1 < heap.count {
                    var child = position * 2 + 1
                    if child + 1 < heap.count && better(heap[child], heap[child + 1]) { child += 1 }
                    guard better(heap[position], heap[child]) else { break }
                    heap.swapAt(position, child); position = child
                }
            }
        }
        for catalog in catalogs {
            for row in 0..<catalog.count {
                if let record = catalog.record(at: row) { try accept(record, native: nil) }
            }
        }
        if let native {
            let namespace = UUID()
            // Native eligibility/ranking comes directly from the shared engine,
            // including root names and its byte-level fuzzy semantics.
            let matches = QueryEngine().matches(query, in: native, isCancelled: isCancelled)
            for match in matches {
                if isCancelled() { throw CancellationError() }
                let id = match.id
                let record = FileRecord(id: id, name: native.name(of: id), path: native.path(of: id), parent: native.parent(of: id),
                                        size: native.size(of: id), mtime: native.mtime(of: id), isDir: native.isDir(of: id), volID: native.volID(of: id))
                try accept(CatalogRecord(native: record, catalogID: namespace), native: record, knownScore: match.score)
            }
        }
        if isCancelled() { throw CancellationError() }
        return CatalogSearchPage(hits: heap.sorted(by: better), totalMatches: count)
    }
}
