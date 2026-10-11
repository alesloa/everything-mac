import Foundation
import Testing
@testable import IndexCore

private func duplicateNameStore(_ names: [String], copies: Int = 3) -> FileStore {
    var store = FileStore()
    let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    for copy in 0..<copies {
        let parent = store.append(name: "folder-\(copy)", parent: root, size: 0, mtime: Int64(copy), isDir: true, volID: 1)
        for (offset, name) in names.enumerated() {
            store.append(name: name, parent: parent, size: UInt64(copy * 1000 + offset),
                         mtime: Int64(offset), isDir: false, volID: UInt32(copy + 1))
        }
    }
    return store
}

private final class NameCancellationBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    init(_ remaining: Int) { self.remaining = remaining }
    func cancelled() -> Bool { lock.withLock { remaining -= 1; return remaining <= 0 } }
}

@Test func uniqueDictionaryKeepsExactBytesAndDistinctRecordMetadata() {
    let names = ["README.md", "readme.md", "ReadMe.md", "Résumé.txt", "Re\u{301}sume\u{301}.txt", "report.pdf"]
    let store = duplicateNameStore(names, copies: 100)
    let index = UniqueNameIndex(store: store)
    #expect(index.uniqueNameCount == Set((0..<store.count).map { Data(store.name(of: UInt32($0)).utf8) }).count)
    #expect(index.uniqueNameCount == names.count + 101)
    let engine = QueryEngine()
    let query = Query(text: "RDM", caseInsensitive: false, fuzzy: true)
    let reference = engine.matches(query, in: store)
    let indexed = engine.matches(query, in: store, nameIndex: index)
    #expect(indexed == reference)
    #expect(indexed.count == 100)
    #expect(Set(indexed.map { store.size(of: $0.id) }).count == 100)
    #expect(Set(indexed.map { store.path(of: $0.id) }).count == 100)
}

@Test func bitmapCandidatesPreserveTyposAcrossSixtyFourNameBoundaries() {
    var names = (0..<160).map { "unrelated-\($0).txt" }
    names[62] = "report.pdf"
    names[63] = "annual report.pdf"
    names[64] = "repxrt.pdf"
    names[127] = "report18.pdf"
    let store = duplicateNameStore(names, copies: 4)
    let index = UniqueNameIndex(store: store)
    let engine = QueryEngine()
    for text in ["report", "repotr", "repxrt", "repport", "reprt", "rxpxrt", "report98", "report81", "report1x"] {
        let query = Query(text: text, fuzzy: true)
        #expect(engine.matches(query, in: store, nameIndex: index) == engine.matches(query, in: store))
    }
    // Inspect the 64-way prefilter itself, including the partial final group.
    let pattern = FuzzyMatcher.Pattern("repxrt", caseInsensitive: true)
    let requirement = UniqueNameIndex.Requirement(mask: pattern.mask, allowsMissingCharacter: pattern.takesTypos,
                                                 firstCharacter: FuzzyMatcher.bit(pattern.bytes[0]))
    for layer in index.layers {
        for group in 0..<layer.groupCount {
            let candidates = layer.candidates(in: group, requirements: [requirement])
            for name in (group * 64)..<min(layer.representatives.count, group * 64 + 64) {
                if pattern.fits(layer.masks[name]) {
                    #expect(candidates & (UInt64(1) << (name & 63)) != 0)
                }
            }
        }
    }
}

@Test func uniqueFuzzyResultsAndTopKMatchPerRecordScan() {
    let names = ["report", "report.pdf", "FinalReport.pdf", "annual report.pdf", "r_e_p_o_r_t.pdf",
                 "README.md", "readme.md", "RésuméFinal.pdf", "Re\u{301}sume\u{301}Final.pdf", ".zshrc",
                 "report18.pdf", "catalog.txt", "log.txt"] + (0..<180).map { "file-\($0)-FinalReport.pdf" }
    var store = duplicateNameStore(names, copies: 7)
    store.markDeleted(1)
    store.markDeleted(3)
    let index = UniqueNameIndex(store: store)
    let engine = QueryEngine()
    for text in ["rpt", "repotr", "rdme", "réf", "RDM", "zshrc", "rpt \"pdf\"", "rpt *.pdf", "f?r* rpt", "p"] {
        for ci in [true, false] {
            let query = Query(text: text, caseInsensitive: ci, fuzzy: true)
            let reference = engine.matches(query, in: store)
            let indexed = engine.matches(query, in: store, nameIndex: index)
            #expect(indexed == reference)
            for bestFirst in [true, false] {
                #expect(engine.rankedPrefix(indexed, limit: 25, bestFirst: bestFirst, in: store)
                        == engine.rankedPrefix(reference, limit: 25, bestFirst: bestFirst, in: store))
            }
        }
    }
}

@Test func uniqueExactGlobsQuotesAndWholeWordsMatchPerRecordScan() {
    let store = duplicateNameStore(["report.pdf", "Report.PDF", "annual report.pdf", "r_e_p_o_r_t.pdf",
                                    "catalog.txt", "log.txt", "RésuméFinal.pdf", ".gitignore", "README.md"])
    let index = UniqueNameIndex(store: store)
    let engine = QueryEngine()
    for text in ["", "report", "\"annual report\"", "rep*.pdf", "?eport.*", "*.PDF", "log", "ré", "README"] {
        for ci in [true, false] {
            for wholeWord in [true, false] {
                let query = Query(text: text, caseInsensitive: ci, wholeWord: wholeWord)
                #expect(engine.search(query, in: store, nameIndex: index) == engine.search(query, in: store))
            }
        }
    }
}

@Test func uniqueIndexChecksTombstonesAndRebuildsForAppendedNames() {
    var store = duplicateNameStore(["report.pdf", "README.md"])
    let original = store
    let index = UniqueNameIndex(store: original)
    let engine = QueryEngine()
    let query = Query(text: "rpt", fuzzy: true)
    let old = engine.matches(query, in: original, nameIndex: index)
    store.markDeleted(2)
    // A tombstoned representative remains valid name bytes for other live copies.
    #expect(engine.matches(query, in: store, nameIndex: index) == engine.matches(query, in: store))
    store.append(name: "FinalReport.pdf", parent: 0, size: 22, mtime: 5, isDir: false, volID: 4)
    let updated = UniqueNameIndex.forSnapshot(store)
    #expect(engine.matches(query, in: store, nameIndex: updated) == engine.matches(query, in: store))
    #expect(engine.matches(query, in: original, nameIndex: index) == old)
}

@Test func uniqueIndexPathAndRestrictedCandidatesKeepRecordSemantics() {
    let store = duplicateNameStore(["report.pdf", "README.md", "Résumé.txt"])
    let index = UniqueNameIndex(store: store)
    let engine = QueryEngine()
    let candidates: [UInt32] = [2, 3, 6]
    for text in ["rpt", "rdme", "ré"] {
        let query = Query(text: text, fuzzy: true)
        let expected = engine.matches(query, in: store).filter { candidates.contains($0.id) }
        #expect(engine.matches(query, in: store, candidates: candidates, nameIndex: index) == expected)
        let path = Query(text: "fldr rpt", matchPath: true, fuzzy: true)
        #expect(engine.matches(path, in: store, nameIndex: index) == engine.matches(path, in: store))
    }
}

@Test func uniqueIndexConstructionAndScansCancelWithoutPartialResults() {
    let store = duplicateNameStore((0..<110_000).map { "report-\($0).pdf" }, copies: 1)
    #expect(UniqueNameIndex.forSnapshot(store, isCancelled: { true }) == nil)
    let buildBudget = NameCancellationBudget(12)
    #expect(UniqueNameIndex.forSnapshot(store, isCancelled: { buildBudget.cancelled() }) == nil)
    let index = UniqueNameIndex.forSnapshot(store)
    let engine = QueryEngine()
    let scanBudget = NameCancellationBudget(24)
    #expect(engine.matches(Query(text: "rpt", fuzzy: true), in: store, nameIndex: index,
                           isCancelled: { scanBudget.cancelled() }).isEmpty)
    let exactBudget = NameCancellationBudget(24)
    #expect(engine.search(Query(text: "report"), in: store, nameIndex: index,
                          isCancelled: { exactBudget.cancelled() }).isEmpty)
    #expect(engine.matches(Query(text: "rpt", fuzzy: true), in: store, nameIndex: index).count == 110_000)
}

@Test func backgroundNamePreparationPublishesOnlyCompleteDictionary() async throws {
    let store = duplicateNameStore((0..<200_000).map { "file-\($0)-FinalReport.pdf" }, copies: 1)
    let preparation = UniqueNameIndex.Preparation(store: store)
    let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(5))
    var ready = preparation.ready()
    while ready == nil && clock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
        ready = preparation.ready()
    }
    #expect(ready != nil)
    if let ready {
        #expect(ready.layers.reduce(0) { $0 + $1.recordNames.count } == store.count)
        let engine = QueryEngine(), query = Query(text: "fnlrpt", fuzzy: true)
        #expect(engine.matches(query, in: store, nameIndex: ready) == engine.matches(query, in: store))
    }
}

@Test func obsoletePreparationsCancelAndCurrentPreparationStillCompletes() async throws {
    let store = duplicateNameStore((0..<200_000).map { "file-\($0)-FinalReport.pdf" }, copies: 1)
    for _ in 0..<30 {
        let obsolete = UniqueNameIndex.Preparation(store: store)
        obsolete.cancel()
        obsolete.cancel() // Explicit cancellation and deinit release only once.
        #expect(obsolete.ready() == nil)
    }
    let current = UniqueNameIndex.Preparation(store: store)
    let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(5))
    while current.ready() == nil && clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(current.ready()?.layers.reduce(0) { $0 + $1.recordNames.count } == store.count)
}

@Test func uniqueNameRealCacheBenchmark() throws {
    guard let path = ProcessInfo.processInfo.environment["UNIQUE_NAME_BENCH_CACHE"] else { return }
    let store = try IndexCache.load(from: URL(fileURLWithPath: path)).0
    let clock = ContinuousClock(), start = clock.now
    let names = UniqueNameIndex.forSnapshot(store)
    print("[perf] unique-name build: \(start.duration(to: clock.now)), records=\(store.count), distinct=\(names.uniqueNameCount), derived-bytes=\(names.derivedByteCount)")
    let engine = QueryEngine()
    func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    for fuzzy in [true, false] {
        for text in ["report", "repotr", "rdme", "package", "p"] {
            let query = Query(text: text, fuzzy: fuzzy)
            var baseline: [Double] = [], indexed: [Double] = []
            for _ in 0..<3 {
                let before = clock.now
                let reference = fuzzy ? engine.matches(query, in: store) : engine.search(query, in: store).map { SearchMatch(id: $0, score: 0) }
                let referenceIDs = engine.rankedPrefix(reference, limit: 5000, in: store)
                let referencePaths = referenceIDs.map { store.path(of: $0) }
                baseline.append(milliseconds(before.duration(to: clock.now)))
                let after = clock.now
                let matches = fuzzy ? engine.matches(query, in: store, nameIndex: names)
                    : engine.search(query, in: store, nameIndex: names).map { SearchMatch(id: $0, score: 0) }
                let ids = engine.rankedPrefix(matches, limit: 5000, in: store)
                let paths = ids.map { store.path(of: $0) }
                indexed.append(milliseconds(after.duration(to: clock.now)))
                #expect(matches == reference)
                #expect(paths == referencePaths)
            }
            print("[perf] unique-name \(fuzzy ? "fuzzy" : "exact") '\(text)' median-ms: baseline=\(String(format: "%.2f", baseline.sorted()[1])), indexed=\(String(format: "%.2f", indexed.sorted()[1]))")
        }
    }
}
