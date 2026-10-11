import Foundation
import Testing
@testable import IndexCore

private func catalogTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-test-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private func importFixture(_ text: String, directory: URL, suffix: String = "efu") throws -> FileCatalogSnapshot {
    let input = directory.appendingPathComponent(UUID().uuidString + "." + suffix)
    try Data(text.utf8).write(to: input)
    return try CatalogIO.importFile(from: input, to: directory.appendingPathComponent(UUID().uuidString + ".efcatalog"))
}
private final class CatalogCancelAfterChecks: @unchecked Sendable {
    private let lock = NSLock()
    private var checks = 0
    private let threshold: Int
    init(_ threshold: Int) { self.threshold = threshold }
    var cancelled: Bool { lock.withLock { checks += 1; return checks >= threshold } }
}

@Suite struct CatalogTests {
    @Test func exactFiletimeAndUnknownMetadataRoundtrip() throws {
        let directory = try catalogTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try importFixture("\u{FEFF}Filename,Size,Date Modified,Date Created,Attributes\r\n\"C:\\line\n\"\"quoted\"\".txt\",18446744073709551615,18446744073709551615,0,0x20\r\n\\\\server\\share\\unknown.txt,,,,\r\n", directory: directory)
        #expect(snapshot.count == 2)
        let first = try #require(snapshot.record(at: 0)), unknown = try #require(snapshot.record(at: 1))
        #expect(first.size == UInt64.max)
        #expect(first.modified?.filetime == UInt64.max)
        #expect(first.created?.filetime == 0)
        #expect(first.path == "C:\\line\n\"quoted\".txt")
        #expect(unknown.size == nil && unknown.modified == nil && unknown.created == nil && unknown.isDirectory == nil)
        for format in [CatalogFormat.efu, .csv, .tsv] {
            let export = directory.appendingPathComponent("roundtrip." + format.rawValue)
            #expect(try CatalogIO.exportRows([first, unknown], to: export, format: format) == 2)
            let imported = try CatalogIO.importFile(from: export, to: directory.appendingPathComponent(format.rawValue + ".efcatalog"))
            let roundtrip = try #require(imported.record(at: 0))
            #expect(roundtrip.path == first.path && roundtrip.size == first.size && roundtrip.modified == first.modified && roundtrip.created == first.created)
            #expect(imported.record(at: 1)?.size == nil && imported.record(at: 1)?.modified == nil)
        }
    }

    @Test func repeatedHeadersAndPathsHaveDistinctRowIdentity() throws {
        let directory = try catalogTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try importFixture("Filename,Filename,Size\nignored,C:\\same.txt,4\nignored,C:\\same.txt,7\n", directory: directory)
        #expect(snapshot.record(at: 0)?.path == "C:\\same.txt")
        #expect(snapshot.record(at: 0)?.id != snapshot.record(at: 1)?.id)
        #expect(try CatalogSearch.search([snapshot], query: Query(text: "same"), limit: 5).totalMatches == 2)
    }

    @Test func unknownNumericDatesAndTypesStayUnknownUnderNot() throws {
        let directory = try catalogTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let localDay = try #require(Calendar.current.date(from: DateComponents(year: 1970, month: 1, day: 1, hour: 12)))
        let ticks = try #require(CatalogTimestamp(seconds: Int64(localDay.timeIntervalSince1970)).filetime)
        let snapshot = try importFixture("Filename,Size,Date Modified,Directory\nunknown.txt,,,\nzero.txt,0,\(ticks),false\nfolder/,1,,true\n", directory: directory)
        #expect(try CatalogSearch.search([snapshot], query: Query(text: "size:0")).hits.map(\.record.name) == ["zero.txt"])
        #expect(try CatalogSearch.search([snapshot], query: Query(text: "NOT size:0")).hits.map(\.record.name) == ["folder"])
        #expect(try CatalogSearch.search([snapshot], query: Query(text: "dm:1970-01-01")).totalMatches == 1)
        #expect(try CatalogSearch.search([snapshot], query: Query(text: "NOT dm:1970-01-01")).totalMatches == 0)
        #expect(try CatalogSearch.search([snapshot], query: Query(text: "file:")).hits.map(\.record.name) == ["zero.txt"])
        #expect(try CatalogSearch.search([snapshot], query: Query(text: "unknown OR size:0")).totalMatches == 2)
        #expect(try CatalogSearch.search([snapshot], query: Query(text: ""), sort: .size, ascending: false).hits.last?.record.name == "unknown.txt")
    }

    @Test func sharedQuerySyntaxAndTextOptions() throws {
        let directory = try catalogTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try importFixture("Filename,Size,Directory\nC:\\folder\\café-report.pdf,4096,false\nC:\\folder\\other.txt,1,false\n/Volumes/Archive/mac.txt,1,false\n", directory: directory)
        #expect(try CatalogSearch.search([snapshot], query: Query(text: "(ext:pdf OR ext:doc) size:>1KiB")).totalMatches == 1)
        #expect(try CatalogSearch.search([snapshot], query: Query(text: "cafereport", diacriticInsensitive: true, ignorePunctuation: true)).totalMatches == 1)
        #expect(try CatalogSearch.search([snapshot], query: Query(text: "parent:\"C:\\folder\" ext:pdf")).totalMatches == 1)
        #expect(try CatalogSearch.search([snapshot], query: Query(text: "parent:/Volumes/Archive ext:txt")).totalMatches == 1)
        #expect(throws: QueryValidationError.self) { try CatalogSearch.search([snapshot], query: Query(text: "size:garbage")) }
    }

    @Test func isoDatesKeepFractionalPrecisionAndFolders() throws {
        let directory = try catalogTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try importFixture("Filename,Date Modified,Date Created\nC:\\folder\\,2026-09-23T21:31:00.1234567Z,2026-09-23T21:31:00\n", directory: directory)
        #expect(snapshot.record(at: 0)?.modified?.nanoseconds == 123_456_700)
        #expect(snapshot.record(at: 0)?.isDirectory == true)
        #expect(snapshot.record(at: 0)?.created != nil)
    }

    @Test func mappingRejectsTraversalPrefixCollisionsAndSymlinkEscapes() throws {
        let directory = try catalogTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("root"), outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        let mapping = CatalogPathMapping(sourcePrefix: "C:\\Media", localRoot: root)
        #expect(try mapping.resolve("c:\\media\\safe.txt").path == root.appendingPathComponent("safe.txt").path)
        for path in ["C:\\Media\\..\\outside", "C:\\Media\\escape\\file", "C:\\MediaOther\\file", "\\\\server\\Media\\file"] {
            #expect(throws: CatalogError.self) { try mapping.resolve(path) }
        }
        let mac = CatalogPathMapping(sourcePrefix: "/Volumes/Archive", localRoot: root)
        #expect(throws: CatalogError.self) { try mac.resolve("Volumes/Archive/file") }
        #expect(try mac.resolve("/Volumes/Archive/quote\\name").lastPathComponent == "quote\\name")
        let unc = CatalogPathMapping(sourcePrefix: "\\\\server\\share", localRoot: root)
        #expect(try unc.resolve("\\\\server\\share\\file").lastPathComponent == "file")
        #expect(throws: CatalogError.self) { try unc.resolve("\\server\\share\\file") }
    }

    @Test func txtQuotedNewlinesRoundtrip() throws {
        let directory = try catalogTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try importFixture("\"/Volumes/Offline/line\n\"\"quote\"\".txt\"\r\nC:\\offline\\file\r\n", directory: directory, suffix: "txt")
        let export = directory.appendingPathComponent("paths.txt")
        #expect(try CatalogIO.exportMatching([snapshot], query: Query(text: ""), to: export, format: .txt) == 2)
        let copy = try CatalogIO.importFile(from: export, to: directory.appendingPathComponent("copy.efcatalog"))
        #expect(copy.record(at: 0)?.path == snapshot.record(at: 0)?.path)
        #expect(copy.record(at: 1)?.modified == nil)
    }

    @Test func fullNativeExportExceedsDisplayLimitAndUsesStableSnapshot() throws {
        let directory = try catalogTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        var store = FileStore()
        let root = store.append(name: "/fixture", parent: FileStore.noParent, size: 0, mtime: 1, isDir: true, volID: 1)
        for index in 0..<10_003 { store.append(name: "match-\(index).txt", parent: root, size: UInt64(index), mtime: 1, isDir: false, volID: 1) }
        let index = SearchIndex(); index.publish(store)
        let stable = index.readSnapshot()
        store.append(name: "match-later.txt", parent: root, size: 1, mtime: 1, isDir: false, volID: 1); index.publish(store)
        let page = try CatalogSearch.search([], native: stable, query: Query(text: "match"), limit: 3)
        #expect(page.hits.count == 3 && page.totalMatches == 10_003)
        let export = directory.appendingPathComponent("all.csv")
        #expect(try CatalogIO.exportNative(store: stable, query: Query(text: "match"), to: export, format: .csv) == 10_003)
        let imported = try CatalogIO.importFile(from: export, to: directory.appendingPathComponent("all.efcatalog"))
        #expect(imported.count == 10_003)
        #expect(try CatalogSearch.search([imported], query: Query(text: "later")).totalMatches == 0)
    }

    @Test func cancelledWritesPreserveDestinationAndSearchThrows() throws {
        let directory = try catalogTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try importFixture("Filename\nfile.txt\n", directory: directory)
        let destination = directory.appendingPathComponent("preserve.csv")
        try Data("original".utf8).write(to: destination)
        #expect(throws: CancellationError.self) { try CatalogIO.exportMatching([snapshot], query: Query(text: ""), to: destination, format: .csv, isCancelled: { true }) }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
        #expect(throws: CancellationError.self) { try CatalogSearch.search([snapshot], query: Query(text: ""), isCancelled: { true }) }
        #expect(throws: CatalogError.self) { try importFixture("Filename\n\"unfinished", directory: directory) }
    }

    @Test func cancellationMidStreamAndFailedImportKeepOldFile() throws {
        let directory = try catalogTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let contents = "Filename,Size\n" + (0..<1000).map { "C:\\item-\($0).txt,\($0)\n" }.joined()
        let snapshot = try importFixture(contents, directory: directory)
        let destination = directory.appendingPathComponent("existing.efu")
        try Data("original".utf8).write(to: destination)
        let exportCancel = CatalogCancelAfterChecks(100)
        #expect(throws: CancellationError.self) {
            try CatalogIO.exportMatching([snapshot], query: Query(text: ""), to: destination, format: .efu, isCancelled: { exportCancel.cancelled })
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
        let source = directory.appendingPathComponent("source.efu")
        try Data(contents.utf8).write(to: source)
        let importCancel = CatalogCancelAfterChecks(100)
        #expect(throws: CancellationError.self) {
            try CatalogIO.importFile(from: source, to: snapshot.url, isCancelled: { importCancel.cancelled })
        }
        #expect(try CatalogIO.load(from: snapshot.url).count == 1000)
        #expect(snapshot.record(at: 999)?.size == 999)
    }

    @Test func nativeExportSortMatchesNativeEngineAndJSONOmitsUnknowns() throws {
        let directory = try catalogTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        var store = FileStore()
        let root = store.append(name: "/fixture", parent: FileStore.noParent, size: 0, mtime: 1, isDir: true, volID: 1)
        store.append(name: "z.txt", parent: root, size: 1, mtime: 1, isDir: false, volID: 1)
        store.append(name: "a.txt", parent: root, size: 9, mtime: 2, isDir: false, volID: 1)
        store.append(name: "b.txt", parent: root, size: 3, mtime: 3, isDir: false, volID: 1)
        let query = Query(text: "ext:txt"), engine = QueryEngine()
        #expect(try CatalogSearch.search([], native: store, query: Query(text: "/fixture")).totalMatches == 1)
        for key in [QueryEngine.SortKey.name, .size, .mtime, .path, .kind] {
            let expected = engine.sort(engine.search(query, in: store), by: key, ascending: false, in: store).map { store.path(of: $0) }
            let destination = directory.appendingPathComponent("sorted.csv")
            #expect(try CatalogIO.exportNative(store: store, query: query, sort: key, ascending: false, to: destination, format: .csv) == 3)
            let imported = try CatalogIO.importFile(from: destination, to: directory.appendingPathComponent("sorted.efcatalog"))
            #expect((0..<imported.count).compactMap { imported.record(at: $0)?.path } == expected)
        }
        let unknown = try importFixture("Filename\nC:\\unknown.txt\n", directory: directory)
        let json = directory.appendingPathComponent("metadata.json")
        #expect(try CatalogIO.exportMatching([unknown], query: Query(text: ""), to: json, format: .json) == 1)
        let values = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [[String: Any]])
        #expect(values.first?["size"] == nil && values.first?["modified"] == nil && values.first?["id"] == nil)
        #expect(values.first?["path"] as? String == "C:\\unknown.txt")
    }

    @Test func nativeExportFolderScopeUsesAncestryAndExcludesSelectedFolder() throws {
        let directory = try catalogTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        var store = FileStore()
        let root = store.append(name: "/root", parent: FileStore.noParent, size: 0, mtime: 1, isDir: true, volID: 1)
        let folder = store.append(name: "folder", parent: root, size: 0, mtime: 1, isDir: true, volID: 1)
        let lookalike = store.append(name: "folder-other", parent: root, size: 0, mtime: 1, isDir: true, volID: 1)
        store.append(name: "include.txt", parent: folder, size: 1, mtime: 1, isDir: false, volID: 1)
        store.append(name: "exclude.txt", parent: lookalike, size: 1, mtime: 1, isDir: false, volID: 1)
        let output = directory.appendingPathComponent("scoped.txt")
        #expect(try CatalogIO.exportNative(store: store, query: Query(text: ""), folderPath: "/root/folder", to: output, format: .txt) == 1)
        #expect(try String(contentsOf: output, encoding: .utf8) == "/root/folder/include.txt\r\n")
        #expect(throws: CatalogError.self) {
            try CatalogIO.exportNative(store: store, query: Query(text: ""), folderPath: "/root/missing", to: output, format: .txt)
        }
        #expect(try String(contentsOf: output, encoding: .utf8) == "/root/folder/include.txt\r\n")
    }
}
