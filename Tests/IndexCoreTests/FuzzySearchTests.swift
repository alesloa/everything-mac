import Foundation
import Testing
@testable import IndexCore

private func fuzzyStore(_ names: [String]) -> FileStore {
    var store = FileStore()
    let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    for name in names {
        store.append(name: name, parent: root, size: 1, mtime: 0, isDir: false, volID: 1)
    }
    return store
}

private func fuzzyNames(_ text: String, in store: FileStore, ci: Bool = true,
                        wholeWord: Bool = false, matchPath: Bool = false) -> [String] {
    QueryEngine().search(Query(text: text, matchPath: matchPath, caseInsensitive: ci,
                               wholeWord: wholeWord, fuzzy: true), in: store).map { store.name(of: $0) }
}

private final class CancellationBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = 32
    func exhausted() -> Bool {
        lock.withLock {
            remaining -= 1
            return remaining <= 0
        }
    }
}

@Test func fuzzySubsequenceIsOptional() {
    let store = fuzzyStore(["FinalReport.pdf", "photo.jpg"])
    #expect(fuzzyNames("fnlrpt", in: store) == ["FinalReport.pdf"])
    #expect(QueryEngine().search(Query(text: "fnlrpt"), in: store).isEmpty)
}

@Test func fuzzyRanksWholeNamesThenStemsThenPrefixes() {
    let store = fuzzyStore(["x-r_e_p_o_r_t.txt", "report-extra.pdf", "report.pdf", "report"])
    let engine = QueryEngine()
    let matches = engine.matches(Query(text: "report", fuzzy: true), in: store)
    let ranked = engine.rankedPrefix(matches, limit: 20, in: store).map { store.name(of: $0) }
    #expect(ranked == ["report", "report.pdf", "report-extra.pdf", "x-r_e_p_o_r_t.txt"])
}

@Test func fuzzyUsesWordAndCamelCaseBoundaries() {
    let store = fuzzyStore(["fxxbxx", "FooBar.txt"])
    let engine = QueryEngine()
    let matches = engine.matches(Query(text: "fb", fuzzy: true), in: store)
    #expect(engine.rankedPrefix(matches, limit: 1, in: store).map { store.name(of: $0) } == ["FooBar.txt"])
}

@Test func fuzzyAllowsOneLetterTypoForLongWords() {
    let store = fuzzyStore(["report.pdf", "annual report.pdf"])
    for query in ["repotr", "repxrt", "repport", "reprt"] {
        #expect(Set(fuzzyNames(query, in: store)) == ["report.pdf", "annual report.pdf"])
    }
    #expect(fuzzyNames("rxpxrt", in: store).isEmpty)
    #expect(fuzzyNames("qreport", in: store).isEmpty)
}

@Test func fuzzyDoesNotCorrectDigitsOrShortWords() {
    let store = fuzzyStore(["report18.pdf", "cat.txt"])
    #expect(fuzzyNames("report98", in: store).isEmpty)
    #expect(fuzzyNames("report81", in: store).isEmpty)
    #expect(fuzzyNames("report1x", in: store).isEmpty)
    #expect(fuzzyNames("cut", in: store).isEmpty)
}

@Test func fuzzyKeepsQuotesGlobsAndWholeWordsExact() {
    let store = fuzzyStore(["report.pdf", "r_e_p_o_r_t.pdf", "catalog.txt", "log.txt"])
    #expect(fuzzyNames("\"report\"", in: store) == ["report.pdf"])
    #expect(fuzzyNames("rep*.pdf", in: store) == ["report.pdf"])
    #expect(fuzzyNames("repotr*.pdf", in: store).isEmpty)
    #expect(fuzzyNames("log", in: store, wholeWord: true) == ["log.txt"])
    #expect(fuzzyNames("rpt", in: store, wholeWord: true).isEmpty)
    #expect(fuzzyNames("rpt \"pdf\"", in: store).count == 2)
}

@Test func fuzzySupportsUnicodeAndCaseSensitiveMatching() {
    let store = fuzzyStore(["RésuméFinal.pdf", "README.md", "readme.txt", ".zshrc"])
    #expect(fuzzyNames("réf", in: store) == ["RésuméFinal.pdf"])
    #expect(fuzzyNames("RdM", in: store, ci: false).isEmpty)
    #expect(fuzzyNames("RDM", in: store, ci: false) == ["README.md"])
    #expect(fuzzyNames("zshrc", in: store) == [".zshrc"])
    #expect(fuzzyNames(".zshrc", in: store) == [".zshrc"])
}

@Test func fuzzyPathMatchesAndTombstonesStayHidden() {
    var store = fuzzyStore(["Docs"])
    let doc = store.append(name: "report.pdf", parent: 1, size: 0, mtime: 0, isDir: false, volID: 1)
    #expect(fuzzyNames("dcs rpt", in: store, matchPath: true) == ["report.pdf"])
    #expect(fuzzyNames("dcs rpt", in: store).isEmpty)
    store.markDeleted(doc)
    #expect(fuzzyNames("rpt", in: store).isEmpty)
}

@Test func fuzzyMasksRebuildFromCompatibleCaches() throws {
    let store = fuzzyStore(["FinalReport.pdf", "RésuméFinal.pdf"])
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try IndexCache.save(store, to: url, lastEventID: 42, rulesFingerprint: 12)
    let loaded = try IndexCache.load(from: url).0
    for query in ["fnlrpt", "réf", "repotr"] {
        #expect(fuzzyNames(query, in: loaded) == fuzzyNames(query, in: store))
    }
}

@Test func corruptNameArenaDoesNotReachUnsafeSearchViews() {
    let store = fuzzyStore(["report.pdf"])
    var data = store.serializedBinary()
    // EMS1 + name-byte array count + payload + offset array count.
    let offsets = 4 + 8 + "/report.pdf".utf8.count + 8
    var invalidOffset = UInt32.max
    withUnsafeBytes(of: &invalidOffset) { data.replaceSubrange(offsets..<(offsets + 4), with: $0) }
    #expect(FileStore(binary: data) == nil)
    var overflowingCount = store.serializedBinary()
    var invalidCount = UInt64.max
    withUnsafeBytes(of: &invalidCount) { overflowingCount.replaceSubrange(4..<12, with: $0) }
    #expect(FileStore(binary: overflowingCount) == nil)
}

@Test func fuzzyTopKHasStableTiesAndMatchesFullRanking() {
    let store = fuzzyStore((0..<200).map { "report-\(($0 * 73) % 200).pdf" } + ["report.pdf", "report.pdf"])
    let engine = QueryEngine()
    let matches = engine.matches(Query(text: "rpt", fuzzy: true), in: store)
    for bestFirst in [true, false] {
        let full = engine.rankedPrefix(matches, limit: matches.count, bestFirst: bestFirst, in: store)
        let top = engine.rankedPrefix(matches, limit: 25, bestFirst: bestFirst, in: store)
        #expect(top == Array(full.prefix(25)))
        #expect(engine.rankedPrefix(matches, limit: 0, in: store).isEmpty)
    }
}

@Test func searchSnapshotsPublishUpdatesWithoutChangingOldResults() async {
    let index = SearchIndex()
    var store = fuzzyStore(["report.pdf"])
    index.publish(store)
    let old = await index.search(Query(text: "rpt", fuzzy: true))
    store.markDeleted(1)
    store.append(name: "FinalReport.pdf", parent: 0, size: 2, mtime: 0, isDir: false, volID: 1)
    // Writer's unpublished changes do not leak into queries.
    #expect(await index.search(Query(text: "rpt", fuzzy: true)) == old)
    index.publish(store)
    let new = await index.search(Query(text: "rpt", fuzzy: true))
    #expect(old.map(\.name) == ["report.pdf"])
    #expect(new.map(\.name) == ["FinalReport.pdf"])
    #expect(index.count == 2)
    #expect(index.path(of: 1) == nil)
}

@Test func cancelledSearchAndZeroLimitDoNotPublishResults() async {
    let index = SearchIndex()
    index.publish(fuzzyStore(["report.pdf"]))
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await index.search(Query(text: "rpt", fuzzy: true))
    }
    #expect(await task.value.isEmpty)
    #expect(await index.search(Query(text: "rpt", fuzzy: true), limit: 0).isEmpty)
    #expect(QueryEngine().matches(Query(text: "rpt", fuzzy: true), in: fuzzyStore(["report.pdf"]),
                                  isCancelled: { true }).isEmpty)
}

@Test func cacheWriterCannotOverwriteANewerSnapshot() async throws {
    let writer = IndexCacheWriter()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try await writer.save(fuzzyStore(["new.pdf"]), to: url, lastEventID: 22, rulesFingerprint: 2, revision: 2)
    try await writer.save(fuzzyStore(["old.pdf"]), to: url, lastEventID: 11, rulesFingerprint: 1, revision: 1)
    let cache = try IndexCache.load(from: url)
    #expect(cache.0.name(of: 1) == "new.pdf")
    #expect(cache.1 == 22)
    #expect(cache.2 == 2)
}

@Test func fuzzySearchOnOneMillionRecords() async {
    var store = FileStore()
    let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    for i in 0..<1_000_000 {
        store.append(name: "file\(i)-FinalReport.pdf", parent: root, size: 0, mtime: 0, isDir: false, volID: 1)
    }
    let index = SearchIndex()
    index.publish(store)
    let clock = ContinuousClock(), start = clock.now
    let hits = await index.search(Query(text: "fnlrpt", fuzzy: true), limit: 100)
    let duration = start.duration(to: clock.now)
    print("[perf] 1M-record fuzzy search + top 100 + paths: \(duration)")
    #expect(hits.count == 100)
    #expect(duration < .seconds(5))
    let cancellation = CancellationBudget()
    let engine = QueryEngine()
    // Cancel during a scan rather than only before the worker starts.
    let partial = engine.matches(Query(text: "fnlrpt", fuzzy: true), in: store, isCancelled: {
        cancellation.exhausted()
    })
    #expect(partial.isEmpty)
}

@Test func fuzzySearchRealCacheBenchmark() async throws {
    // Opt-in, read-only: no full disk scan and no writes to the user's cache.
    guard let path = ProcessInfo.processInfo.environment["FUZZY_BENCH_CACHE"] else { return }
    let store = try IndexCache.load(from: URL(fileURLWithPath: path)).0
    let index = SearchIndex()
    index.publish(store)
    print("[perf] fuzzy benchmark cache entries: \(store.count)")
    let clock = ContinuousClock()
    for text in ["report", "repotr", "rdme", "package", "p"] {
        let start = clock.now
        let engine = QueryEngine()
        let matches = engine.matches(Query(text: text, fuzzy: true), in: store)
        let scanned = clock.now
        let ids = engine.rankedPrefix(matches, limit: 5000, in: store)
        let sorted = clock.now
        let paths = ids.map { store.path(of: $0) }
        print("[perf] fuzzy '\(text)': scan=\(start.duration(to: scanned)), rank=\(scanned.duration(to: sorted)), paths=\(sorted.duration(to: clock.now)), matches=\(matches.count), rows=\(paths.count)")
        let serviceStart = clock.now
        let records = await index.search(Query(text: text, fuzzy: true), limit: 5000)
        print("[perf] SearchIndex '\(text)' end-to-end: \(serviceStart.duration(to: clock.now)), rows=\(records.count)")
        #expect(records.map(\.path) == paths)
    }
}
