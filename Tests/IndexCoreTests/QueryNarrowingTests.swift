import Foundation
import Testing
@testable import IndexCore

private func narrowingStore(_ names: [String]) -> FileStore {
    var store = FileStore()
    let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    let docs = store.append(name: "Docs", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
    for (i, name) in names.enumerated() {
        store.append(name: name, parent: docs, size: UInt64(i + 1), mtime: Int64(i), isDir: false, volID: 1)
    }
    return store
}

private func fullNarrowingResults(_ query: Query, store: FileStore, sort: QueryEngine.SortKey,
                                  ascending: Bool, limit: Int) -> [UInt32] {
    let engine = QueryEngine()
    if query.hasFuzzyTerms && sort == .relevance {
        return engine.rankedPrefix(engine.matches(query, in: store), limit: limit,
                                   bestFirst: ascending, in: store)
    }
    return engine.sortedPrefix(engine.search(query, in: store), by: sort,
                               ascending: ascending, limit: limit, in: store)
}

private func compareNarrowingSequence(_ queries: [Query], store: FileStore,
                                      sort: QueryEngine.SortKey = .relevance,
                                      ascending: Bool = true, limit: Int = 5000) async {
    let index = SearchIndex()
    index.publish(store)
    for query in queries {
        let expected = fullNarrowingResults(query, store: store, sort: sort, ascending: ascending, limit: limit)
        let actual = await index.search(query, sort: sort, ascending: ascending, limit: limit)
        #expect(actual.map(\.id) == expected, "Query: \(query.text)")
    }
}

@Test func queryNarrowingOnlyReusesMonotonicTokenEdits() {
    #expect(Query(text: "repo").narrows(Query(text: "rep")))
    #expect(Query(text: "REP", fuzzy: true).narrows(Query(text: "re", fuzzy: true)))
    #expect(Query(text: "repotr", fuzzy: true).narrows(Query(text: "repot", fuzzy: true)))
    #expect(Query(text: "\"report\" pdf", fuzzy: true).narrows(Query(text: "\"rep\" pd", fuzzy: true)))
    #expect(Query(text: "réf", fuzzy: true).narrows(Query(text: "ré", fuzzy: true)))
    #expect(!Query(text: "repor", fuzzy: true).narrows(Query(text: "repo", fuzzy: true)))
    #expect(!Query(text: "rep", fuzzy: true).narrows(Query(text: "repo", fuzzy: true)))
    #expect(!Query(text: "rep*").narrows(Query(text: "rep")))
    #expect(!Query(text: "repo*").narrows(Query(text: "rep*")))
    #expect(!Query(text: "\"repo\"", fuzzy: true).narrows(Query(text: "rep", fuzzy: true)))
    #expect(!Query(text: "rep pdf").narrows(Query(text: "rep")))
    #expect(!Query(text: "catalog", wholeWord: true).narrows(Query(text: "cat", wholeWord: true)))
    #expect(!Query(text: "ké", fuzzy: true).narrows(Query(text: "k", fuzzy: true)))
    #expect(!Query(text: "rep", matchPath: true).narrows(Query(text: "re")))
    #expect(!Query(text: "rep", caseInsensitive: false).narrows(Query(text: "re")))
    #expect(!Query(text: "rep", wholeWord: true).narrows(Query(text: "re")))
    #expect(!Query(text: "rep", fuzzy: true).narrows(Query(text: "re")))
    #expect(!Query(text: "rep").narrows(Query(text: "")))
    let boundary = String(repeating: "a", count: 128)
    #expect(!Query(text: boundary + "b", fuzzy: true).narrows(Query(text: boundary, fuzzy: true)))
}

@Test func queryNarrowingResetsOnTypoWideningAndWholeWordEdits() async {
    let store = narrowingStore(["rebor", "report", "repotr", "catalog", "cat", "Kée", "kée"])
    await compareNarrowingSequence(["r", "re", "rep", "repo", "repor", "report", "repotr", "repo", "re"]
        .map { Query(text: $0, fuzzy: true) }, store: store)
    await compareNarrowingSequence([Query(text: "cat", wholeWord: true), Query(text: "catalog", wholeWord: true)], store: store)
    await compareNarrowingSequence([Query(text: "k", fuzzy: true), Query(text: "ké", fuzzy: true),
                                    Query(text: "kée", fuzzy: true)], store: store)
    let boundary = String(repeating: "a", count: 128)
    await compareNarrowingSequence([boundary, boundary + "b", boundary].map { Query(text: $0, fuzzy: true) },
                                   store: narrowingStore([boundary, boundary + "b", boundary + "c"]))
    #expect(QueryEngine().search(Query(text: "repo", fuzzy: true), in: store).contains(2) == false)
    #expect(QueryEngine().search(Query(text: "repor", fuzzy: true), in: store).contains(2))
}

@Test func queryNarrowingPreservesQuotesGlobsPathsCaseAndUnicode() async {
    var store = narrowingStore(["report.pdf", "r_e_p_o_r_t.pdf", "RésuméFinal.pdf", "Résumé.pdf",
                                "README.md", "readme.txt", "annual report.pdf", "Résumé-été.txt"])
    store.markDeleted(3)
    let texts = ["r", "ré", "réf", "r", "rep", "\"rep\"", "\"report\"", "rep*", "rep*.pdf",
                 "r pdf", "re pdf", "rep pd", "RDM", "README", "Docs rpt", "Docs report", ""]
    for fuzzy in [true, false] {
        for ci in [true, false] {
            for path in [true, false] {
                await compareNarrowingSequence(texts.map { Query(text: $0, matchPath: path,
                                                                 caseInsensitive: ci, fuzzy: fuzzy) }, store: store)
            }
        }
    }
    // Composed/decomposed characters and grapheme growth must follow the matcher.
    await compareNarrowingSequence(["Ré", "Re\u{301}", "Re\u{301}s", "Réf", "Réf\u{301}"]
        .map { Query(text: $0, fuzzy: true) }, store: store)
    await compareNarrowingSequence([Query(text: "rpt", fuzzy: true), Query(text: "rpt"),
                                    Query(text: "rep", wholeWord: true), Query(text: "rep", matchPath: true),
                                    Query(text: "REP", caseInsensitive: false)], store: store)
}

@Test func queryNarrowingCachesAllCandidatesAndRescoresForEverySort() async {
    let store = narrowingStore((0..<250).map { "report-\($0).pdf" } + ["r_e_p_o_r_t.pdf", "report", "report.pdf"])
    let queries = ["r", "re", "rep", "repo", "repor", "report", "report-2"].map { Query(text: $0, fuzzy: true) }
    for sort in [QueryEngine.SortKey.relevance, .name, .path, .size, .mtime, .kind] {
        for ascending in [true, false] {
            await compareNarrowingSequence(queries, store: store, sort: sort, ascending: ascending, limit: 3)
        }
    }
    let index = SearchIndex()
    index.publish(store)
    _ = await index.search(Query(text: "r", fuzzy: true), limit: 1)
    let narrowed = Query(text: "report-2", fuzzy: true)
    #expect(await index.search(narrowed, limit: 5000).map(\.id)
            == fullNarrowingResults(narrowed, store: store, sort: .relevance, ascending: true, limit: 5000))
    #expect(QueryEngine().matches(narrowed, in: store).count > 1)
}

@Test func queryNarrowingSnapshotChangesInvalidateCandidates() async {
    var store = narrowingStore(["report.pdf"])
    let index = SearchIndex()
    index.publish(store)
    _ = await index.search(Query(text: "re", fuzzy: true), limit: 1)
    store.markDeleted(2)
    let added = store.append(name: "replacement.pdf", parent: 1, size: 1, mtime: 0, isDir: false, volID: 1)
    index.publish(store)
    let query = Query(text: "rep", fuzzy: true)
    let hits = await index.search(query)
    #expect(hits.map(\.id) == [added])
}

@Test func queryNarrowingOneEditPrefixesRemainComplete() {
    // Exhaust every five-to-six-character extension over letters and a digit,
    // including edits crossing the old end, against short exhaustive filenames.
    let alphabet = ["a", "b", "1"]
    func words(_ length: Int) -> [String] {
        (0..<length).reduce([""]) { result, _ in result.flatMap { prefix in alphabet.map { prefix + $0 } } }
    }
    let store = narrowingStore(words(4) + words(5) + words(6) + words(7))
    let engine = QueryEngine()
    for prefix in words(5) {
        let previous = Query(text: prefix, fuzzy: true)
        let candidates = engine.search(previous, in: store)
        for letter in alphabet {
            let query = Query(text: prefix + letter, fuzzy: true)
            let eligibilityChanged = prefix == "11111" && letter != "1"
            #expect(query.narrows(previous) == !eligibilityChanged)
            #expect(engine.matches(query, in: store, candidates: eligibilityChanged ? nil : candidates)
                    == engine.matches(query, in: store),
                    "Prefix: \(prefix), appended: \(letter)")
        }
    }
}

private final class NarrowingCancellationBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = 2
    func exhausted() -> Bool { lock.withLock { remaining -= 1; return remaining <= 0 } }
}

@Test func queryNarrowingCandidateScansCancelAndValidateIDs() {
    let store = narrowingStore((0..<3000).map { "report-\($0).pdf" })
    let candidates = QueryEngine().search(Query(text: "re"), in: store)
    for fuzzy in [true, false] {
        let budget = NarrowingCancellationBudget()
        let hits = QueryEngine().search(Query(text: "rep", fuzzy: fuzzy), in: store, candidates: candidates,
                                        isCancelled: { budget.exhausted() })
        #expect(hits.isEmpty)
        let valid = QueryEngine().search(Query(text: "rep", fuzzy: fuzzy), in: store, candidates: [2, .max])
        #expect(valid == [2])
    }
}

@Test func queryNarrowingConcurrentCacheWritesRemainComplete() async {
    let store = narrowingStore((0..<400).map { "report-\($0).pdf" } + ["README.md", "package.json", "Résumé.pdf"])
    let index = SearchIndex()
    index.publish(store)
    await withTaskGroup(of: Void.self) { group in
        for text in ["r", "re", "rep", "repo", "repor", "report", "rdme", "package", "ré", "rép", ""] {
            group.addTask {
                let query = Query(text: text, fuzzy: true)
                let actual = await index.search(query, limit: 7)
                #expect(actual.map(\.id) == fullNarrowingResults(query, store: store, sort: .relevance,
                                                               ascending: true, limit: 7))
            }
        }
    }
}

@Test func queryNarrowingRealCacheBenchmark() async throws {
    guard let path = ProcessInfo.processInfo.environment["NARROWING_BENCH_CACHE"] else { return }
    let store = try IndexCache.load(from: URL(fileURLWithPath: path)).0
    let engine = QueryEngine(), clock = ContinuousClock()
    print("[perf] narrowing cache entries: \(store.count)")
    for texts in [["pa", "pac", "pack", "packa", "packag", "package"], ["r", "re", "rep", "repo", "repor", "report"]] {
        let index = SearchIndex()
        index.publish(store)
        var previous: Query?, candidates: [UInt32]?
        for text in texts {
            let query = Query(text: text, fuzzy: true)
            let start = clock.now
            let full = engine.matches(query, in: store)
            let fullTime = start.duration(to: clock.now)
            let reuse = previous.map { query.narrows($0) } ?? false
            let narrowStart = clock.now
            let narrowed = engine.matches(query, in: store, candidates: reuse ? candidates : nil)
            let narrowTime = narrowStart.duration(to: clock.now)
            #expect(narrowed == full)
            let serviceStart = clock.now
            let records = await index.search(query, limit: 5000)
            let serviceTime = serviceStart.duration(to: clock.now)
            #expect(records.map(\.id) == engine.rankedPrefix(full, limit: 5000, in: store))
            print("[perf] narrowing '\(text)': reuse=\(reuse), candidates=\(reuse ? candidates?.count ?? 0 : store.count), full=\(fullTime), narrowed=\(narrowTime), service=\(serviceTime), matches=\(full.count)")
            previous = query
            candidates = full.map(\.id)
        }
    }
}

@Test func literalQueryCachePreservesDistinctUnicodeScalarSpellings() async {
    let store = narrowingStore(["Résumé.txt", "Re\u{301}sume\u{301}.txt"])
    let composed = Query(text: "Ré")
    let decomposed = Query(text: "Re\u{301}")
    #expect(composed != decomposed)
    #expect(!decomposed.narrows(composed))
    let index = SearchIndex()
    index.publish(store)
    let first = await index.search(composed)
    let second = await index.search(decomposed)
    #expect(first.map(\.id) == QueryEngine().search(composed, in: store))
    #expect(second.map(\.id) == QueryEngine().search(decomposed, in: store))
    #expect(first.map(\.id) == [2] && second.map(\.id) == [3])
}
