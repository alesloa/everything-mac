import IndexCore

extension IndexActor {
    nonisolated func search(_ query: Query, sort: QueryEngine.SortKey,
                            ascending: Bool, limit: Int) async -> [FileRecord] {
        await searchIndex.search(query, sort: sort, ascending: ascending, limit: limit)
    }
}
