import Foundation
import Testing
@testable import IndexCore

private func namedStore(_ names: [String]) -> FileStore {
    var store = FileStore()
    let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    let parent = store.append(name: "Folder", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
    for (offset, name) in names.enumerated() {
        store.append(name: name, parent: parent, size: UInt64(offset), mtime: Int64(offset), isDir: false, volID: 1)
    }
    return store
}

// Reference semantics: the Unicode-scalar matcher every record used before the byte path.
private func referenceIDs(_ query: Query, in store: FileStore) -> [UInt32] {
    (0..<UInt32(store.count)).filter { id in
        let text = query.matchPath ? store.path(of: id) : store.name(of: id)
        return query.terms.allSatisfy { Glob.matches(pattern: $0, in: text, caseInsensitive: query.caseInsensitive) }
    }
}

@Test func caseSensitiveASCIITermsMatchExactBytesOnEverySearchPath() {
    let names = ["Report.pdf", "report.pdf", "REPORT.PDF", "Final Report.pdf", "Résumé Report.pdf",
                 "Re\u{301}sume\u{301}.txt", "📄 Report.md", "data-Report_1640x720.png", "data-report_1640x720.png",
                 "README", "ReadMe", "x"]
    let store = namedStore(names)
    let index = UniqueNameIndex(store: store)
    let engine = QueryEngine()
    let everyID = Array(0..<UInt32(store.count))
    // "*R?port*" reaches the Unicode-scalar glob through non-ASCII names.
    for text in ["Report", "report", "REPORT", "Rep*", "*.PDF", "R?port*", "*R?port*", "*r?port*",
                 "*Report_1640x720.png", "Report md",
                 "Résumé", "\u{301}sume", "📄 Rep", "Folder", "z"] {
        for matchPath in [false, true] {
            let query = Query(text: text, matchPath: matchPath, caseInsensitive: false)
            let expected = referenceIDs(query, in: store)
            #expect(engine.search(query, in: store, nameIndex: index) == expected, "name index: \(text)")
            #expect(engine.search(query, in: store) == expected, "full scan: \(text)")
            #expect(engine.search(query, in: store, candidates: everyID) == expected, "candidates: \(text)")
        }
    }
    #expect(engine.search(Query(text: "Report", caseInsensitive: false), in: store, nameIndex: index).count == 5)
    #expect(engine.search(Query(text: "Report", caseInsensitive: true), in: store, nameIndex: index).count == 8)
}

@Test func caseSensitiveFuzzyLiteralsMatchExactBytes() {
    let names = ["Final Report.pdf", "final report.pdf", "FINAL REPORT.PDF", "Résumé Final.pdf"]
    let store = namedStore(names)
    let index = UniqueNameIndex(store: store)
    let engine = QueryEngine()
    for text in ["Fnl \"Report\"", "fnl \"report\"", "Fnl \"*.pdf\"", "Fnl \"Résumé\""] {
        let query = Query(text: text, caseInsensitive: false, fuzzy: true)
        let reference = engine.matches(query, in: store).map(\.id)
        #expect(engine.matches(query, in: store, nameIndex: index).map(\.id) == reference, "\(text)")
    }
    let exact = engine.matches(Query(text: "Fnl \"Report\"", caseInsensitive: false, fuzzy: true),
                               in: store, nameIndex: index)
    #expect(!exact.isEmpty)
    #expect(exact.allSatisfy { store.name(of: $0.id).contains("Report") })
}

// A live index re-runs the query after every filesystem change. Case-sensitive
// search once built a String for every unique name, which on a full-disk index
// kept every core busy for seconds per refresh.
@Test func caseSensitiveSearchKeepsTheUniqueNamePrefilter() {
    let names = (0..<200_000).map { "Item-\($0)-Alpha.txt" }
    let store = namedStore(names)
    let index = UniqueNameIndex(store: store)
    let engine = QueryEngine()
    let clock = ContinuousClock()
    func best(_ caseInsensitive: Bool) -> Duration {
        let query = Query(text: "chilitos-fb-cover_1640x720s.png", caseInsensitive: caseInsensitive)
        return (0..<3).map { _ in
            let start = clock.now
            #expect(engine.search(query, in: store, nameIndex: index).isEmpty)
            return start.duration(to: clock.now)
        }.min()!
    }
    let insensitive = best(true), sensitive = best(false)
    print("[perf] 200k unique names, no-hit query: ignore-case=\(insensitive) case-sensitive=\(sensitive)")
    #expect(sensitive < insensitive * 10 + .milliseconds(20))
}
