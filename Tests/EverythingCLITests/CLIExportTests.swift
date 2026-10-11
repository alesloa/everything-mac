import Foundation
import Darwin
import Testing
import IndexCore

extension EverythingCLITests {
    @Test func nulPathsPreserveUnicodeAndFilenameDelimitersExactly() throws {
        let fixture = try CLIProcessFixture()
        fixture.store.append(name: "cafe\u{301}.txt", parent: 2, size: 1, mtime: 0, isDir: false, volID: 1)
        try IndexCache.save(fixture.store, to: fixture.cache, lastEventID: 71, rulesFingerprint: 93)
        let query = Query(text: "ext:txt")
        let expected = try CatalogSearch.nativeIDs(store: fixture.store, query: query)
        var expectedBytes = Data()
        for id in expected { expectedBytes.append(Data(fixture.store.path(of: id).utf8)); expectedBytes.append(0) }
        let actual = try fixture.run(["--null", "ext:txt"])
        #expect(actual.status == 0 && actual.stderr.isEmpty && actual.stdout == expectedBytes)
        #expect(actual.stdout.contains(9) && actual.stdout.contains(10) && actual.stdout.contains(34) && actual.stdout.contains(44))
        #expect(actual.stdout.last == 0)
        #expect(!actual.text.contains("deleted.txt"))
    }

    @Test func everyCatalogFormatUsesTheSharedSerializerAndPreservesMetadata() throws {
        let fixture = try CLIProcessFixture()
        for format in CatalogFormat.allCases {
            let expected = fixture.directory.appendingPathComponent("expected." + format.rawValue)
            try CatalogIO.exportNative(store: fixture.store, query: Query(text: ""), sort: .size,
                                       ascending: false, folderPath: "/fixture/folder", to: expected, format: format)
            let actual = try fixture.run(["--folder", "/fixture/folder", "--sort", "size", "--descending", "--format", format.rawValue])
            #expect(try actual.status == 0 && actual.stderr.isEmpty && actual.stdout == Data(contentsOf: expected))
            if format == .json {
                let rows = try #require(JSONSerialization.jsonObject(with: actual.stdout) as? [[String: Any]])
                #expect(rows.count == 5)
                #expect(rows.allSatisfy { $0["created"] == nil && $0["attributes"] == nil && $0["id"] == nil })
                let odd = try #require(rows.first { ($0["path"] as? String)?.contains("comma,") == true })
                #expect(odd["size"] as? Int == 0 && odd["directory"] as? Bool == false)
                let modified = try #require(odd["modified"] as? [String: Any])
                #expect(modified["seconds"] as? Int == 0 && modified["nanoseconds"] as? Int == 0)
            } else {
                let output = fixture.directory.appendingPathComponent("actual." + format.rawValue)
                try actual.stdout.write(to: output)
                let snapshot = try CatalogIO.importFile(from: output,
                    to: fixture.directory.appendingPathComponent(format.rawValue + ".efcatalog"), format: format)
                #expect(snapshot.count == 5)
                let records = (0..<snapshot.count).compactMap { snapshot.record(at: $0) }
                #expect(records.contains { $0.path == "/fixture/folder/nested/comma,tab\tquote\"line\n.txt" })
                #expect(records.allSatisfy { $0.created == nil })
                if format != .txt {
                    #expect(records.contains { $0.size == 0 && $0.modified?.seconds == 0 && $0.isDirectory == false })
                }
            }
        }
        let zero = try fixture.run(["--format=json", "--limit=0"])
        let zeroRows = try JSONSerialization.jsonObject(with: zero.stdout) as? [Any]
        #expect(zero.status == 0 && zeroRows?.isEmpty == true)
    }

    @Test func fullResultsAndExplicitLimitsExceedTheAppDisplayCap() throws {
        let fixture = try CLIProcessFixture(extraRows: 10_003)
        let all = try fixture.run(["bulk-"])
        #expect(all.status == 0 && all.paths.count == 10_003 && all.stderr.isEmpty)
        let limited = try fixture.run(["--limit", "7001", "bulk-"])
        #expect(limited.status == 0 && limited.paths.count == 7001)
        let json = try fixture.run(["--format", "json", "bulk-"])
        let rows = try #require(JSONSerialization.jsonObject(with: json.stdout) as? [[String: Any]])
        #expect(rows.count == 10_003)
        let csv = try fixture.run(["--format", "csv", "bulk-"])
        let output = fixture.directory.appendingPathComponent("all.csv")
        try csv.stdout.write(to: output)
        let imported = try CatalogIO.importFile(from: output, to: fixture.directory.appendingPathComponent("all.efcatalog"))
        #expect(imported.count == 10_003)
    }

    @Test func closedPipeExitsQuietlyAndOutputFailuresGoOnlyToStderr() throws {
        let fixture = try CLIProcessFixture(extraRows: 20_000)
        let pipe = Pipe(), diagnostic = Pipe()
        let child = fixture.process(["bulk-"], stdout: pipe, stderr: diagnostic)
        try child.run()
        try pipe.fileHandleForReading.close()
        try pipe.fileHandleForWriting.close()
        try diagnostic.fileHandleForWriting.close()
        try CLIProcessFixture.wait(child)
        #expect(child.terminationStatus == 0 && child.terminationReason == .exit)
        #expect(try diagnostic.fileHandleForReading.readToEnd()?.isEmpty != false)
        let original = try Data(contentsOf: fixture.cache)
        let readonly = try FileHandle(forReadingFrom: fixture.cache)
        defer { try? readonly.close() }
        for arguments in [["Report"], ["--help"], ["--version"]] {
            let err = Pipe()
            let failing = fixture.process(arguments, stdout: readonly, stderr: err)
            try failing.run(); try err.fileHandleForWriting.close()
            try CLIProcessFixture.wait(failing)
            let error = String(decoding: try err.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
            #expect(failing.terminationStatus == 4 && error.contains("Bad file descriptor"))
        }
        #expect(try Data(contentsOf: fixture.cache) == original)
    }

    @Test func interruptAndTerminateCancelBlockedOutputWithoutChangingCache() throws {
        let fixture = try CLIProcessFixture(extraRows: 20_000)
        let original = try Data(contentsOf: fixture.cache)
        for deliveredSignal in [SIGINT, SIGTERM] {
            let pipe = Pipe(), diagnostic = Pipe()
            let child = fixture.process(["--format", "json", "bulk-"], stdout: pipe, stderr: diagnostic)
            try child.run()
            try pipe.fileHandleForWriting.close(); try diagnostic.fileHandleForWriting.close()
            // Reading one byte proves the child installed its signal handlers,
            // finished searching, and began output into a deliberately full pipe.
            let first = try pipe.fileHandleForReading.read(upToCount: 1)
            #expect(first?.isEmpty == false)
            #expect(kill(child.processIdentifier, deliveredSignal) == 0)
            try CLIProcessFixture.wait(child)
            #expect(child.terminationReason == .exit && child.terminationStatus == 128 + deliveredSignal)
            try pipe.fileHandleForReading.close()
            #expect(try diagnostic.fileHandleForReading.readToEnd()?.isEmpty != false)
            #expect(try Data(contentsOf: fixture.cache) == original)
        }
    }
}
