import Foundation
import Darwin
import Testing
import IndexCore

@Suite(.serialized) struct EverythingCLITests {
    @Test func readOnlyLoadKeepsSearchResultsAndDefaultLoadKeepsWriterChildren() throws {
        let fixture = try CLIProcessFixture()
        let original = try Data(contentsOf: fixture.cache)
        var (writer, event, fingerprint) = try IndexCache.load(from: fixture.cache)
        let (reader, readerEvent, readerFingerprint) = try IndexCache.load(from: fixture.cache, buildWriterIndex: false)
        #expect(event == 71 && fingerprint == 93 && readerEvent == event && readerFingerprint == fingerprint)
        #expect(writer.childIDs(of: 1) == fixture.store.childIDs(of: 1))
        #expect(reader.childIDs(of: 1).isEmpty)
        #expect(try CatalogSearch.nativeIDs(store: writer, query: Query(text: "ext:txt"))
                == CatalogSearch.nativeIDs(store: reader, query: Query(text: "ext:txt")))
        writer.markSubtreeDeleted(1)
        #expect(!writer.isLive(2) && !writer.isLive(4) && reader.isLive(2) && reader.isLive(4))
        #expect(try Data(contentsOf: fixture.cache) == original)
    }

    @Test func helpVersionAndArgumentValidationDoNotReadCache() throws {
        let fixture = try CLIProcessFixture()
        let missing = fixture.directory.appendingPathComponent("missing.idx")
        let help = try fixture.run(["--help"], cache: missing)
        #expect(help.status == 0 && help.text.contains("--null") && help.stderr.isEmpty)
        let version = try fixture.run(["--version"], cache: missing)
        #expect(version.status == 0 && version.text == IndexCore.version + "\n" && version.stderr.isEmpty)
        for arguments in [["--unknown"], ["--limit", "-1"], ["--limit", "999999999999999999999"],
                          ["--sort", "invented"], ["--format", "invented"], ["--null", "--format", "json"],
                          ["--fuzzy=true"], ["--cache"]] {
            let result = try fixture.run(arguments, cache: missing)
            #expect(result.status == 2 && result.stdout.isEmpty && !result.stderr.isEmpty)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func sharedQueryAndEveryModifierReachTheNativeEngine() throws {
        let fixture = try CLIProcessFixture()
        let result = try fixture.run(["(ext:pdf OR ext:txt) size:>1KiB NOT folder:"])
        #expect(result.status == 0 && result.paths == ["/fixture/folder/Report.pdf"] && result.stderr.isEmpty)
        let cases: [([String], Query)] = [
            (["--case-sensitive", "Report"], Query(text: "Report", caseInsensitive: false)),
            (["--ignore-case", "REPORT"], Query(text: "REPORT")),
            (["--match-path", "folder/nested"], Query(text: "folder/nested", matchPath: true)),
            (["--whole-word", "report"], Query(text: "report", wholeWord: true)),
            (["--fuzzy", "rpt"], Query(text: "rpt", fuzzy: true)),
            (["--regex", "^Report\\.pdf$"], Query(text: "^Report\\.pdf$", regex: true)),
            (["--diacritic-insensitive", "cafe"], Query(text: "cafe", diacriticInsensitive: true)),
            (["--prefix", "Report"], Query(text: "Report", matchPrefix: true)),
            (["--suffix", ".pdf"], Query(text: ".pdf", matchSuffix: true)),
            (["--ignore-punctuation", "cafénotes"], Query(text: "cafénotes", ignorePunctuation: true)),
            (["--ignore-whitespace", "spacename"], Query(text: "spacename", ignoreWhitespace: true)),
            (["--", "-dash"], Query(text: "-dash")),
            (["dm:>=2023-11-14 ext:pdf"], Query(text: "dm:>=2023-11-14 ext:pdf")),
        ]
        for (arguments, query) in cases {
            let expected = try CatalogSearch.nativeIDs(store: fixture.store, query: query).map { fixture.store.path(of: $0) }
            let actual = try fixture.run(["-0"] + arguments, preserveArgumentBytes: true)
            #expect(actual.status == 0 && actual.stderr.isEmpty)
            let actualPaths = actual.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            #expect(actualPaths == expected, "Arguments: \(arguments)")
        }
        let invalidQueries = ["size:garbage", "(report", "\"unclosed", "ext:pdf OR"]
        for text in invalidQueries {
            let error = try #require(Query(text: text).validationError)
            let actual = try fixture.run([text])
            #expect(actual.status == 2 && actual.stdout.isEmpty && actual.diagnostic == error.localizedDescription + "\n")
        }
        let regex = try fixture.run(["--regex", "["])
        #expect(regex.status == 2 && regex.stdout.isEmpty && !regex.stderr.isEmpty)
    }

    @Test func allSortKeysDirectionsAndLimitsMatchSharedSemantics() throws {
        let fixture = try CLIProcessFixture()
        let cases: [(String, QueryEngine.SortKey)] = [("name", .name), ("path", .path), ("size", .size),
                                                    ("modified", .mtime), ("kind", .kind), ("relevance", .relevance)]
        for (name, key) in cases {
            for ascending in [true, false] {
                let args = ["--sort=\(name)", ascending ? "--ascending" : "--descending", "--limit=3", "-0", "ext:txt"]
                let actual = try fixture.run(args)
                let expected = try CatalogSearch.nativeIDs(store: fixture.store, query: Query(text: "ext:txt"),
                                                          sort: key, ascending: ascending, limit: 3)
                    .map { fixture.store.path(of: $0) }
                #expect(actual.status == 0 && actual.stderr.isEmpty)
                #expect(actual.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) } == expected)
            }
        }
        for ascending in [true, false] {
            let args = ["--fuzzy", "--sort", "relevance", ascending ? "--asc" : "--desc", "--limit", "2", "rpt"]
            let actual = try fixture.run(args)
            let expected = try CatalogSearch.nativeIDs(store: fixture.store, query: Query(text: "rpt", fuzzy: true),
                                                      sort: .relevance, ascending: ascending, limit: 2).map { fixture.store.path(of: $0) }
            #expect(actual.paths == expected)
        }
        #expect(try fixture.run(["--limit", "0"]).stdout.isEmpty)
        #expect(try fixture.run(["no-such-fixture-entry"]).status == 0)
        #expect(try fixture.run(["no-such-fixture-entry"]).stdout.isEmpty)
    }

    @Test func cacheFailuresHaveDefinedExitCodesAndNeverRepairOrChangeCache() throws {
        let fixture = try CLIProcessFixture()
        let original = try Data(contentsOf: fixture.cache)
        #expect(try fixture.run(["report"]).status == 0)
        #expect(try Data(contentsOf: fixture.cache) == original)
        let missing = fixture.directory.appendingPathComponent("missing.idx")
        let absent = try fixture.run([], cache: missing)
        #expect(absent.status == 3 && absent.stdout.isEmpty && absent.diagnostic.contains(missing.path))
        #expect(absent.diagnostic.contains("No such file"))
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        let corrupt = fixture.directory.appendingPathComponent("corrupt.idx")
        let bytes = Data("invalid index".utf8); try bytes.write(to: corrupt)
        let invalid = try fixture.run([], cache: corrupt)
        #expect(invalid.status == 3 && invalid.stdout.isEmpty && invalid.diagnostic.contains("header is invalid"))
        #expect(try Data(contentsOf: corrupt) == bytes)
        let schema = fixture.directory.appendingPathComponent("schema.idx")
        var badSchema = original; badSchema[20] = 0; try badSchema.write(to: schema)
        let invalidSchema = try fixture.run([], cache: schema)
        #expect(invalidSchema.status == 3 && invalidSchema.stdout.isEmpty && invalidSchema.diagnostic.contains("data is invalid"))
        let fifo = fixture.directory.appendingPathComponent("fifo.idx")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let fifoResult = try fixture.run([], cache: fifo)
        #expect(fifoResult.status == 3 && fifoResult.stdout.isEmpty)
        let directory = try fixture.run([], cache: fixture.directory)
        #expect(directory.status == 3 && directory.stdout.isEmpty)
        #expect(try Data(contentsOf: fixture.cache) == original)
    }

    @Test func folderScopeUsesActualCachedAncestryAndIncludesNestedEntries() throws {
        let fixture = try CLIProcessFixture()
        let scoped = try fixture.run(["--folder", "/fixture/folder", "ext:txt", "-0"])
        let paths = scoped.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        #expect(scoped.status == 0 && paths.count == 3)
        #expect(paths.contains("/fixture/folder/nested/café-notes.txt"))
        #expect(!paths.contains("/fixture/folder-other/outside.txt"))
        let all = try fixture.run(["--folder", "/fixture/folder", "--format", "json"])
        let rows = try #require(JSONSerialization.jsonObject(with: all.stdout) as? [[String: Any]])
        #expect(rows.count == 5 && !rows.contains { $0["path"] as? String == "/fixture/folder" })
        for path in ["/fixture/missing", "/fixture/folder/Report.pdf", "/fixture/fold"] {
            let result = try fixture.run(["--folder", path])
            #expect(result.status == 4 && result.stdout.isEmpty && result.diagnostic.contains(path))
        }
    }
}
