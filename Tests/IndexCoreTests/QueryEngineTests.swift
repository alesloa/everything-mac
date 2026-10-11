import Testing
@testable import IndexCore

private func sample() -> FileStore {
    var s = FileStore()
    let root = s.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    let docs = s.append(name: "Docs", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
    _ = s.append(name: "report.pdf", parent: docs, size: 10, mtime: 3, isDir: false, volID: 1)
    _ = s.append(name: "report.txt", parent: docs, size: 20, mtime: 2, isDir: false, volID: 1)
    _ = s.append(name: "photo.jpg", parent: root, size: 30, mtime: 1, isDir: false, volID: 1)
    return s
}

@Test func queryMatchesSubstring() {
    let s = sample()
    let engine = QueryEngine()
    let ids = engine.search(Query(text: "report"), in: s)
    #expect(ids.count == 2)
}

@Test func queryAndsMultipleTerms() {
    let s = sample()
    let engine = QueryEngine()
    let ids = engine.search(Query(text: "report pdf"), in: s)
    #expect(ids.count == 1)
    #expect(s.name(of: ids[0]) == "report.pdf")
}

@Test func queryMatchesPathWhenEnabled() {
    let s = sample()
    let engine = QueryEngine()
    // match-path matches the full path including the item's own name, so "Docs"
    // matches the /Docs folder itself plus both files under it (Everything path: semantics).
    let ids = engine.search(Query(text: "Docs", matchPath: true), in: s)
    #expect(ids.count == 3)
    let names = Set(ids.map { s.name(of: $0) })
    #expect(names == ["Docs", "report.pdf", "report.txt"])
}

@Test func emptyQueryReturnsAll() {
    let s = sample()
    let engine = QueryEngine()
    let ids = engine.search(Query(text: "   "), in: s)
    #expect(ids.count == s.count)
}

@Test func wholeWordMatchesBoundedTermsOnly() {
    var s = FileStore()
    let root = s.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    _ = s.append(name: "log.txt", parent: root, size: 0, mtime: 0, isDir: false, volID: 1)
    _ = s.append(name: "catalog.txt", parent: root, size: 0, mtime: 0, isDir: false, volID: 1)
    _ = s.append(name: "my-log-file", parent: root, size: 0, mtime: 0, isDir: false, volID: 1)
    let engine = QueryEngine()
    // Plain substring "log" hits all three.
    #expect(engine.search(Query(text: "log"), in: s).count == 3)
    // Whole-word "log" matches only where it stands alone (log.txt, my-log-file),
    // NOT inside "catalog".
    let ww = engine.search(Query(text: "log", wholeWord: true), in: s).map { s.name(of: $0) }
    #expect(Set(ww) == ["log.txt", "my-log-file"])
}

@Test func caseSensitiveSearchRespectsCase() {
    var s = FileStore()
    let root = s.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    _ = s.append(name: "README.md", parent: root, size: 0, mtime: 0, isDir: false, volID: 1)
    _ = s.append(name: "readme.txt", parent: root, size: 0, mtime: 0, isDir: false, volID: 1)
    let engine = QueryEngine()
    // Default (insensitive) matches both.
    #expect(engine.search(Query(text: "readme"), in: s).count == 2)
    // Case-sensitive matches only the lowercase one.
    let cs = engine.search(Query(text: "readme", caseInsensitive: false), in: s).map { s.name(of: $0) }
    #expect(cs == ["readme.txt"])
}

@Test func sortsByNameAscending() {
    let s = sample()
    let engine = QueryEngine()
    var ids = engine.search(Query(text: "report"), in: s)
    ids = engine.sort(ids, by: .name, ascending: true, in: s)
    #expect(s.name(of: ids[0]) == "report.pdf")
    #expect(s.name(of: ids[1]) == "report.txt")
}

@Test func sortsBySizeDescending() {
    let s = sample()
    let engine = QueryEngine()
    var ids: [UInt32] = engine.search(Query(text: ""), in: s)
    ids = engine.sort(ids, by: .size, ascending: false, in: s)
    #expect(s.size(of: ids[0]) == 30)
}

@Test func searchExcludesTombstonedRecords() {
    var s = sample()
    let engine = QueryEngine()
    // Find and tombstone report.pdf, then confirm neither the substring query nor
    // the empty (all-records) query surfaces it any more.
    let pdf = engine.search(Query(text: "report.pdf"), in: s)[0]
    s.markDeleted(pdf)
    #expect(s.hasDeletions)
    let reportHits = engine.search(Query(text: "report"), in: s)
    #expect(reportHits.count == 1)                          // only report.txt remains
    #expect(!reportHits.contains(pdf))
    let all = engine.search(Query(text: ""), in: s)
    #expect(!all.contains(pdf))
    #expect(all.count == s.count - 1)
}

@Test func sortsByKindGroupsFoldersThenExtension() {
    var s = FileStore()
    let root = s.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    _ = s.append(name: "photo.JPG", parent: root, size: 1, mtime: 0, isDir: false, volID: 1) // ci ext
    _ = s.append(name: "a.pdf", parent: root, size: 2, mtime: 0, isDir: false, volID: 1)
    _ = s.append(name: "z.jpg", parent: root, size: 3, mtime: 0, isDir: false, volID: 1)
    _ = s.append(name: "Music", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
    _ = s.append(name: "README", parent: root, size: 4, mtime: 0, isDir: false, volID: 1) // no ext
    let engine = QueryEngine()
    let ids = engine.search(Query(text: ""), in: s)
    let sorted = engine.sort(ids, by: .kind, ascending: true, in: s).map { s.name(of: $0) }
    // Folders first (root "/" + Music), then extensionless, then jpg group (ci), then pdf.
    #expect(sorted == ["/", "Music", "README", "photo.JPG", "z.jpg", "a.pdf"])
}

// sortedPrefix must return exactly the first `limit` ids of a full sort, in the
// same order — the bounded heap is an optimization, not a behavior change.
@Test func sortedPrefixMatchesFullSort() {
    var s = FileStore()
    let root = s.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    // 200 names in shuffled-ish order so the heap eviction path is exercised.
    for n in 0..<200 {
        let v = (n * 73) % 200
        _ = s.append(name: "file\(String(format: "%03d", v)).txt", parent: root,
                     size: UInt64(v), mtime: Int64(v), isDir: false, volID: 1)
    }
    let engine = QueryEngine()
    let ids = engine.search(Query(text: "file"), in: s)
    for (key, asc) in [(QueryEngine.SortKey.name, true), (.name, false), (.size, true), (.mtime, false)] {
        let full = engine.sort(ids, by: key, ascending: asc, in: s)
        let top = engine.sortedPrefix(ids, by: key, ascending: asc, limit: 25, in: s)
        #expect(top.count == 25)
        #expect(top == Array(full.prefix(25)))
    }
}
