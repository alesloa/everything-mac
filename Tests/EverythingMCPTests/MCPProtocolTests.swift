import Foundation
import IndexCore
import Testing

@Suite struct EverythingMCPTests {
    @Test func handshakeDiscoverySearchAndCleanEOF() throws {
        let fixture = try MCPProcessFixture()
        let before = try Data(contentsOf: fixture.cache)
        let initialized = try #require(fixture.initialize()["result"] as? [String: Any])
        #expect(initialized["protocolVersion"] as? String == "2025-11-25")
        let info = try #require(initialized["serverInfo"] as? [String: Any])
        #expect(info["name"] as? String == "everything-mac")
        #expect(info["version"] as? String == IndexCore.version)
        let listed = try #require(fixture.request("tools/list")["result"] as? [String: Any])
        let tools = try #require(listed["tools"] as? [[String: Any]])
        #expect(Set(tools.compactMap { $0["name"] as? String }) == ["search_files", "get_index_status"])
        for tool in tools {
            let annotations = try #require(tool["annotations"] as? [String: Any])
            #expect(annotations["readOnlyHint"] as? Bool == true)
            #expect(tool["inputSchema"] != nil && tool["outputSchema"] != nil)
        }
        let result = try fixture.call("search_files", ["query": "ext:pdf"])
        #expect(result["isError"] as? Bool == false)
        let payload = try #require(result["structuredContent"] as? [String: Any])
        #expect(payload["cache_path"] as? String == fixture.cache.path)
        #expect(payload["returned"] as? Int == 1)
        #expect(payload["has_more"] as? Bool == false)
        let rows = try #require(payload["results"] as? [[String: Any]])
        #expect(rows.first?["path"] as? String == "/fixture/Report.pdf")
        #expect(rows.first?["size"] as? Int == 4096)
        #expect(rows.first?["created"] == nil && rows.first?["attributes"] == nil && rows.first?["id"] == nil)
        let modified = try #require(rows.first?["modified"] as? [String: Any])
        #expect(modified["seconds"] as? Int == 1_700_000_000)
        #expect(modified["nanoseconds"] as? Int == 0)
        let content = try #require(result["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
        #expect(decoded == payload as NSDictionary)
        #expect(try Data(contentsOf: fixture.cache) == before)
        try fixture.close()
    }

    @Test func scopedUnicodeSortingLimitsAndExactMetadata() throws {
        let fixture = try MCPProcessFixture(extraRows: 55)
        _ = try fixture.initialize()
        let scoped = try fixture.call("search_files", ["query": "ext:txt", "folder": "/fixture", "sort": "size",
            "descending": true, "limit": 2])
        let page = try #require(scoped["structuredContent"] as? [String: Any])
        #expect(page["returned"] as? Int == 2 && page["has_more"] as? Bool == true)
        let rows = try #require(page["results"] as? [[String: Any]])
        #expect(rows.compactMap { $0["size"] as? Int } == [54, 53])
        let defaults = try #require(fixture.call("search_files", ["query": "ext:txt"])["structuredContent"] as? [String: Any])
        #expect(defaults["returned"] as? Int == 50 && defaults["has_more"] as? Bool == true)
        let zero = try #require(fixture.call("search_files", ["query": "", "limit": 0])["structuredContent"] as? [String: Any])
        #expect(zero["returned"] as? Int == 0 && zero["has_more"] as? Bool == true)
        let unicode = try fixture.call("search_files", ["query": "cafe", "diacritic_insensitive": true])
        let unicodePage = try #require(unicode["structuredContent"] as? [String: Any])
        let unicodeRows = try #require(unicodePage["results"] as? [[String: Any]])
        #expect(unicodeRows.first?["path"] as? String == "/fixture/nested/café,tab\tquote\"line\n.txt")
        #expect(unicodeRows.first?["size"] as? Int == 0)
        let huge = try #require(fixture.call("search_files", ["query": "huge.bin"])["structuredContent"] as? [String: Any])
        let hugeRows = try #require(huge["results"] as? [[String: Any]])
        #expect(hugeRows.first?["size"] as? String == String(UInt64.max))
        let modified = try #require(hugeRows.first?["modified"] as? [String: Any])
        #expect(modified["seconds"] as? Int == -1)
        let scopedAll = try #require(fixture.call("search_files", ["query": "ext:txt", "folder": "/fixture", "limit": 1000])["structuredContent"] as? [String: Any])
        let scopedRows = try #require(scopedAll["results"] as? [[String: Any]])
        #expect(scopedRows.count == 57)
        #expect(!scopedRows.contains { ($0["path"] as? String)?.contains("outside.txt") == true })
        #expect(!scopedRows.contains { ($0["path"] as? String)?.contains("deleted.txt") == true })
        try fixture.close()
    }

    @Test func toolErrorsAreRecoverableAndProtocolErrorsStayDistinct() throws {
        let fixture = try MCPProcessFixture()
        _ = try fixture.initialize()
        let invalid: [[String: Any]] = [[:], ["query": 42], ["query": "", "limit": -1],
            ["query": "", "limit": 1001], ["query": "", "limit": true], ["query": "", "limit": "3"],
            ["query": "", "fuzzy": "true"], ["query": "", "folder": ""], ["query": "", "sort": "invented"],
            ["query": "", "cache": "somewhere"], ["query": "size:>nonsense"],
            ["query": "(", "regex": true], ["query": "", "folder": "/absent"]]
        for arguments in invalid {
            let result = try fixture.call("search_files", arguments)
            #expect(result["isError"] as? Bool == true, "Invalid arguments: \(arguments)")
            #expect(result["structuredContent"] == nil)
            let content = try #require(result["content"] as? [[String: Any]])
            #expect((content.first?["text"] as? String)?.isEmpty == false)
        }
        #expect(try fixture.call("get_index_status", ["extra": 1])["isError"] as? Bool == true)
        let unknown = try fixture.request("tools/call", ["name": "unknown", "arguments": [:]])
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32602)
        let method = try fixture.request("not/a/method")
        #expect((method["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(try fixture.request("ping")["error"] == nil)
        #expect(try fixture.call("search_files", ["query": "ext:pdf"])["isError"] as? Bool == false)
        try fixture.close()
    }

    @Test func missingCorruptAndReplacedCacheNeverReturnStaleResults() throws {
        let fixture = try MCPProcessFixture(saveCache: false)
        let initialized = try #require(fixture.initialize(version: "2024-11-05")["result"] as? [String: Any])
        #expect(initialized["protocolVersion"] as? String == "2024-11-05")
        #expect(try fixture.request("tools/list")["error"] == nil)
        let missing = try fixture.call("get_index_status")
        #expect(missing["isError"] as? Bool == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.cache.path))
        let content = try #require(missing["content"] as? [[String: Any]])
        #expect((content.first?["text"] as? String)?.contains(fixture.cache.path) == true)
        try fixture.save()
        let status = try #require(fixture.call("get_index_status")["structuredContent"] as? [String: Any])
        #expect(status["indexed_entries"] as? Int == 8)
        #expect(status["scan_completed"] as? Bool == true)
        fixture.store.append(name: "new.pdf", parent: 0, size: 7, mtime: 5, isDir: false, volID: 1)
        try fixture.save()
        let fresh = try #require(fixture.call("search_files", ["query": "ext:pdf"])["structuredContent"] as? [String: Any])
        #expect(fresh["returned"] as? Int == 2)
        try Data("corrupt".utf8).write(to: fixture.cache, options: .atomic)
        let corrupt = try fixture.call("search_files", ["query": "ext:pdf"])
        #expect(corrupt["isError"] as? Bool == true && corrupt["structuredContent"] == nil)
        #expect(try Data(contentsOf: fixture.cache) == Data("corrupt".utf8))
        try fixture.save()
        #expect(try fixture.call("search_files", ["query": "ext:pdf"])["isError"] as? Bool == false)
        try fixture.close()
    }
}
