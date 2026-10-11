import Foundation
import Testing
@testable import IndexCore

private func advancedStore() -> FileStore {
    var store = FileStore()
    let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    let docs = store.append(name: "Documents", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
    let nested = store.append(name: "Nested", parent: docs, size: 0, mtime: 0, isDir: true, volID: 1)
    for (name, parent, size) in [("annual report.PDF", docs, UInt64(1_000_000)), ("annual summary.txt", docs, 100),
                                 ("report.md", nested, 2048), ("holiday.JPG", root, 100_000),
                                 ("annual.mp3", root, 2_000_000), ("ext:pdf", root, 42)] {
        store.append(name: name, parent: parent, size: size, mtime: 1_750_000_000, isDir: false, volID: 1)
    }
    return store
}
private func advancedNames(_ query: Query, store: FileStore = advancedStore()) -> Set<String> {
    Set(QueryEngine().search(query, in: store).map { store.name(of: $0) })
}

@Test func advancedFunctionsMatchIndexedMetadataAndPaths() {
    #expect(advancedNames(Query(text: "ext:pdf;txt size:>=100B")) == ["annual report.PDF", "annual summary.txt"])
    #expect(advancedNames(Query(text: "ext:md size:1KiB..3KiB")) == ["report.md"])
    #expect(advancedNames(Query(text: "file:annual")) == ["annual report.PDF", "annual summary.txt", "annual.mp3"])
    #expect(advancedNames(Query(text: "folder:Documents")) == ["Documents"])
    #expect(advancedNames(Query(text: "file: parent:/Documents")) == ["annual report.PDF", "annual summary.txt"])
    #expect(advancedNames(Query(text: "file: path:/Documents")) == ["annual report.PDF", "annual summary.txt", "report.md"])
    #expect(advancedNames(Query(text: "ext:PDF", caseInsensitive: false)) == ["annual report.PDF"])
    #expect(advancedNames(Query(text: "ext:pdf", caseInsensitive: false)).isEmpty)
}

@Test func advancedBooleansHaveCompatiblePrecedenceAndGroups() {
    // OR binds before implicit AND, so an mp3 without "report" is excluded.
    #expect(advancedNames(Query(text: "report ext:pdf | ext:mp3")) == ["annual report.PDF"])
    #expect(advancedNames(Query(text: "(report ext:pdf) OR ext:mp3")) == ["annual report.PDF", "annual.mp3"])
    #expect(advancedNames(Query(text: "<ext:pdf|ext:txt> NOT summary")) == ["annual report.PDF"])
    #expect(advancedNames(Query(text: "file: !<ext:pdf|ext:txt|ext:mp3>")) == ["report.md", "holiday.JPG", "ext:pdf"])
    #expect(advancedNames(Query(text: "file: AND annual NOT ext:mp3")) == ["annual report.PDF", "annual summary.txt"])
}

@Test func advancedQuotedTermsAndRegexPreserveLiteralValues() {
    #expect(advancedNames(Query(text: "\"ext:pdf\"")) == ["ext:pdf"])
    #expect(advancedNames(Query(text: "name:\"annual report\"")) == ["annual report.PDF"])
    #expect(advancedNames(Query(text: "regex:\"^(annual|holiday).*\\.(pdf|jpg)$\"")) == ["annual report.PDF", "holiday.JPG"])
    #expect(advancedNames(Query(text: "^annual.*\\.(PDF|mp3)$", regex: true)) == ["annual report.PDF", "annual.mp3"])
    let raw = "a\"b\\c (x)|!"
    var store = FileStore()
    store.append(name: raw, parent: FileStore.noParent, size: 0, mtime: 0, isDir: false, volID: 1)
    #expect(advancedNames(Query(text: Query.quotedLiteral(raw)), store: store) == [raw])
}

@Test func advancedValidationRejectsMalformedQueryRatherThanWidening() {
    for text in ["ext:", "size:garbage", "size:-1", "size:1.5B", "size:2..1", "size:18446744073709551616",
                 "size:1GB..", "dm:2025-02-30", "dm:tomorrow", "dm:2026-12-01..2026-01-01",
                 "report OR", "AND report", "(report", "<report)", "report)", "\"report", "regex:\"[\""] {
        let query = Query(text: text)
        #expect(query.validationError != nil, "Expected validation error for \(text)")
        #expect(QueryEngine().search(query, in: advancedStore()).isEmpty)
    }
    #expect(Query(text: "size:18446744073709551615").validationError == nil)
    #expect(Query(text: String(repeating: "NOT ", count: 65) + "report").validationError != nil)
    #expect(Query(text: "[", regex: true).validationError != nil)
}

@Test func advancedUnicodeModifiersPrefixSuffixAndWildcardRemainCorrect() {
    var store = FileStore()
    for name in ["Résumé-final.pdf", "Re\u{301}sume\u{301} final.PDF", "catalog cat", "cat.txt", "my file.txt"] {
        store.append(name: name, parent: FileStore.noParent, size: 0, mtime: 0, isDir: false, volID: 1)
    }
    #expect(advancedNames(Query(text: "resume", diacriticInsensitive: true), store: store)
            == ["Résumé-final.pdf", "Re\u{301}sume\u{301} final.PDF"])
    #expect(advancedNames(Query(text: "\"resumefinal\"", diacriticInsensitive: true, ignorePunctuation: true,
                                ignoreWhitespace: true), store: store).count == 2)
    #expect(advancedNames(Query(text: "*resume*pdf", diacriticInsensitive: true, ignorePunctuation: true), store: store).count == 2)
    #expect(advancedNames(Query(text: "pdf", matchSuffix: true), store: store).count == 2)
    #expect(advancedNames(Query(text: "cat", wholeWord: true, matchPrefix: true), store: store) == ["cat.txt"])
    #expect(advancedNames(Query(text: "myfile", ignoreWhitespace: true), store: store) == ["my file.txt"])
}

@Test func advancedDatesUseLocalCalendarDaysAndInvalidateRelativeCache() async {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11))!
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
    var store = FileStore()
    for (name, date) in [("yesterday.txt", yesterday), ("today.txt", today), ("tomorrow.txt", tomorrow)] {
        store.append(name: name, parent: FileStore.noParent, size: 0, mtime: Int64(date.timeIntervalSince1970), isDir: false, volID: 1)
    }
    let q1 = Query(text: "dm:today", referenceDate: today)
    let q2 = Query(text: "dm:today", referenceDate: tomorrow)
    #expect(q1 != q2)
    #expect(advancedNames(q1, store: store) == ["today.txt"])
    #expect(advancedNames(Query(text: "dm:<=2026-10-11"), store: store) == ["yesterday.txt", "today.txt"])
    #expect(advancedNames(Query(text: "dm:2026-10-10..2026-10-11"), store: store) == ["yesterday.txt", "today.txt"])
    let index = SearchIndex()
    index.publish(store)
    #expect(await index.search(q1).map(\.name) == ["today.txt"])
    #expect(await index.search(q2).map(\.name) == ["tomorrow.txt"])
    var automatic = Query(text: "dm:today")
    automatic.plan.dayAnchor = yesterday.timeIntervalSince1970
    #expect(automatic.refreshingRelativeDates().plan.dayAnchor == Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
}

@Test func advancedFilterCompositionWorksWithBooleanQueriesAndRegex() {
    #expect(advancedNames(Query(text: SearchFilter.documents.applying(to: "annual | report")))
            == ["annual report.PDF", "annual summary.txt", "report.md"])
    #expect(advancedNames(SearchFilter.images.applying(to: Query(text: "^holiday", regex: true))) == ["holiday.JPG"])
    var criteria = AdvancedSearchCriteria()
    criteria.name = "annual report"; criteria.extensions = "pdf"; criteria.minimumSize = "1MB"
    #expect(criteria.validationError == nil)
    #expect(advancedNames(Query(text: criteria.queryText)) == ["annual report.PDF"])
    criteria.regularExpression = "(annual|report).*"
    #expect(criteria.validationError == nil)
    criteria.minimumSize = "1 GB"
    #expect(criteria.validationError != nil)
}

private final class AdvancedCancellationBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    init(_ remaining: Int) { self.remaining = remaining }
    func exhausted() -> Bool { lock.withLock { remaining -= 1; return remaining <= 0 } }
}

@Test func advancedSearchCancelsAndNeverReusesUnsafeCandidates() async {
    var store = FileStore()
    for n in 0..<3000 { store.append(name: "report\(n).pdf", parent: FileStore.noParent, size: UInt64(n), mtime: 0, isDir: false, volID: 1) }
    let budget = AdvancedCancellationBudget(3)
    #expect(QueryEngine().search(Query(text: "ext:pdf"), in: store, isCancelled: { budget.exhausted() }).isEmpty)
    #expect(QueryEngine().search(Query(text: "size:>=0"), in: store, candidates: [0, .max]) == [0])
    #expect(!Query(text: "size:>1").narrows(Query(text: "size:>10")))
    let index = SearchIndex()
    index.publish(store)
    for text in ["size:>100", "size:>10", "ext:pdf | folder:", "NOT ext:pdf", "report ext:pdf"] {
        let query = Query(text: text, fuzzy: true)
        #expect(await index.search(query, sort: .name, limit: 5000).map(\.id)
                == QueryEngine().sortedPrefix(QueryEngine().search(query, in: store), by: .name, ascending: true, limit: 5000, in: store))
    }
}

@Test func advancedRegexCanCancelDuringPathologicalBacktracking() {
    var store = FileStore()
    store.append(name: String(repeating: "a", count: 512) + "!", parent: FileStore.noParent, size: 0, mtime: 0, isDir: false, volID: 1)
    let budget = AdvancedCancellationBudget(8)
    #expect(QueryEngine().search(Query(text: "^(a+)+$", regex: true), in: store,
                                isCancelled: { budget.exhausted() }).isEmpty)
}

@Test func advancedParallelMetadataMatchingWorksOnMappedSnapshots() async throws {
    var store = FileStore()
    let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    for n in 0..<120_000 {
        store.append(name: "file\(n).\(n.isMultiple(of: 2) ? "PDF" : "txt")", parent: root,
                     size: UInt64(n), mtime: Int64(n), isDir: false, volID: 1)
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("advanced-query-\(UUID().uuidString).idx")
    defer { try? FileManager.default.removeItem(at: url) }
    try IndexCache.save(store, to: url, lastEventID: 0, rulesFingerprint: 0)
    let mapped = try IndexCache.load(from: url).0
    let query = Query(text: "ext:pdf size:>=60000")
    let expected = stride(from: 60_000, to: 120_000, by: 2).map { UInt32($0 + 1) }
    #expect(QueryEngine().search(query, in: mapped) == expected)
    let index = SearchIndex()
    index.publish(mapped)
    #expect(await index.search(query, sort: .size, limit: 50_000).map(\.id) == expected)
}
