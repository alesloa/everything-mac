import Foundation

extension CatalogSearch {
    /// Searches a captured native index, retaining compact IDs rather than full
    /// rows. A nil limit returns every match; folder scope follows parent IDs.
    public static func nativeIDs(store: FileStore, query input: Query,
                                 sort: QueryEngine.SortKey = .name, ascending: Bool = true,
                                 limit: Int? = nil, folderPath: String? = nil,
                                 isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> [UInt32] {
        if let error = input.validationError { throw error }
        let query = input.refreshingRelativeDates(), engine = QueryEngine()
        let candidates = try CatalogNativeScope.candidates(folderPath: folderPath, in: store, isCancelled: isCancelled)
        let ids: [UInt32]
        if query.hasFuzzyTerms && sort == .relevance {
            let matches = engine.matches(query, in: store, candidates: candidates, isCancelled: isCancelled)
            ids = engine.rankedPrefix(matches, limit: limit ?? matches.count, bestFirst: ascending,
                                      in: store, isCancelled: isCancelled)
        } else {
            let matches = engine.search(query, in: store, candidates: candidates, isCancelled: isCancelled)
            ids = engine.sortedPrefix(matches, by: sort, ascending: ascending, limit: limit ?? matches.count,
                                      in: store, isCancelled: isCancelled)
        }
        if isCancelled() { throw CancellationError() }
        return ids
    }
}
