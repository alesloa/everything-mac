import Foundation
import Darwin
import IndexCore
import Testing

// Real JSON-RPC processes, independently encoded/decoded with Foundation rather
// than the server SDK. All index writes are confined to this temporary fixture.
final class MCPProcessFixture {
    let directory: URL
    let cache: URL
    let executable: URL
    var store = FileStore()
    let child = Process()
    private let input = Pipe(), output = Pipe()
    private var pending = Data()
    private var nextID = 0

    init(saveCache: Bool = true, extraRows: Int = 0) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("everything-mcp-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cache = directory.appendingPathComponent("fixture.idx")
        if let override = ProcessInfo.processInfo.environment["EVERYTHING_MCP_BINARY"] {
            executable = URL(fileURLWithPath: override)
        } else {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            #if DEBUG
            executable = root.appendingPathComponent(".build/debug/everything-mcp")
            #else
            executable = root.appendingPathComponent(".build/release/everything-mcp")
            #endif
        }
        let folder = store.append(name: "/fixture", parent: FileStore.noParent, size: 0, mtime: 1, isDir: true, volID: 1)
        let nested = store.append(name: "nested", parent: folder, size: 0, mtime: 2, isDir: true, volID: 1)
        let outside = store.append(name: "/fixture-other", parent: FileStore.noParent, size: 0, mtime: 3, isDir: true, volID: 2)
        store.append(name: "Report.pdf", parent: folder, size: 4096, mtime: 1_700_000_000, isDir: false, volID: 1)
        store.append(name: "report.txt", parent: folder, size: 12, mtime: 1_700_000_001, isDir: false, volID: 1)
        store.append(name: "café,tab\tquote\"line\n.txt", parent: nested, size: 0, mtime: 0, isDir: false, volID: 1)
        store.append(name: "outside.txt", parent: outside, size: 99, mtime: 4, isDir: false, volID: 2)
        store.append(name: "huge.bin", parent: folder, size: UInt64.max, mtime: -1, isDir: false, volID: 1)
        let dead = store.append(name: "deleted.txt", parent: folder, size: 1, mtime: 1, isDir: false, volID: 1)
        store.markDeleted(dead)
        for row in 0..<extraRows {
            store.append(name: "bulk-\(row).txt", parent: folder, size: UInt64(row), mtime: Int64(row), isDir: false, volID: 1)
        }
        if saveCache { try save() }
        child.executableURL = executable
        child.arguments = ["--cache", cache.path]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        try child.run()
    }

    deinit {
        try? input.fileHandleForWriting.close()
        if child.isRunning {
            kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func save() throws { try IndexCache.save(store, to: cache, lastEventID: 71, rulesFingerprint: 93) }

    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func request(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        nextID += 1
        try send(["jsonrpc": "2.0", "id": nextID, "method": method, "params": params])
        let response = try receive()
        #expect(response["jsonrpc"] as? String == "2.0")
        #expect(response["id"] as? Int == nextID)
        return response
    }

    func initialize(version: String = "2025-11-25") throws -> [String: Any] {
        let response = try request("initialize", ["protocolVersion": version, "capabilities": [:],
            "clientInfo": ["name": "everything-mcp-tests", "version": "1"]])
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        return response
    }

    func call(_ name: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
        let response = try request("tools/call", ["name": name, "arguments": arguments])
        return try #require(response["result"] as? [String: Any])
    }

    private func receive() throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let newline = pending.firstIndex(of: 10) {
                let line = pending[..<newline]
                pending = Data(pending[(newline + 1)...])
                return try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 && errno == EINTR { continue }
            if ready > 0 {
                // Foundation's read(upToCount:) can wait to fill the requested
                // count on a pipe. A single POSIX read consumes available bytes
                // so the response deadline also covers short MCP messages.
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = bytes.withUnsafeMutableBytes {
                    Darwin.read(descriptor.fd, $0.baseAddress!, $0.count)
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw MCPFixtureError(message: "MCP exited before returning JSON-RPC.") }
                pending.append(contentsOf: bytes.prefix(count))
            }
        }
        throw MCPFixtureError(message: "MCP response exceeded test deadline.")
    }

    func close() throws {
        try input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(5)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !child.isRunning else { throw MCPFixtureError(message: "MCP did not exit after stdin closed.") }
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)
    }
}

struct MCPFixtureError: Error { let message: String }
