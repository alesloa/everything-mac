import Foundation
import Darwin
import IndexCore
import Testing

struct CLIProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
    var text: String { String(decoding: stdout, as: UTF8.self) }
    var diagnostic: String { String(decoding: stderr, as: UTF8.self) }
    var paths: [String] { text.split(separator: "\n").map(String.init) }
}

final class CLIProcessFixture {
    let directory: URL
    let cache: URL
    let executable: URL
    var store = FileStore()

    init(extraRows: Int = 0) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("everything-cli-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cache = directory.appendingPathComponent("fixture.idx")
        if let override = ProcessInfo.processInfo.environment["EVERYTHING_CLI_BINARY"] {
            executable = URL(fileURLWithPath: override)
        } else {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            #if DEBUG
            executable = root.appendingPathComponent(".build/debug/everything")
            #else
            executable = root.appendingPathComponent(".build/release/everything")
            #endif
        }
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
        let root = store.append(name: "/fixture", parent: FileStore.noParent, size: 0, mtime: 1, isDir: true, volID: 1)
        let folder = store.append(name: "folder", parent: root, size: 0, mtime: 2, isDir: true, volID: 1)
        let nested = store.append(name: "nested", parent: folder, size: 0, mtime: 3, isDir: true, volID: 1)
        let lookalike = store.append(name: "folder-other", parent: root, size: 0, mtime: 4, isDir: true, volID: 1)
        store.append(name: "Report.pdf", parent: folder, size: 4096, mtime: 1_700_000_000, isDir: false, volID: 1)
        store.append(name: "report.txt", parent: folder, size: 12, mtime: 1_700_000_001, isDir: false, volID: 1)
        store.append(name: "café-notes.txt", parent: nested, size: 23, mtime: 1_700_000_002, isDir: false, volID: 1)
        store.append(name: "comma,tab\tquote\"line\n.txt", parent: nested, size: 0, mtime: 0, isDir: false, volID: 1)
        store.append(name: "outside.txt", parent: lookalike, size: 99, mtime: 1_700_000_003, isDir: false, volID: 1)
        store.append(name: "-dash.txt", parent: root, size: 5, mtime: 1_700_000_004, isDir: false, volID: 1)
        store.append(name: "space name.txt", parent: root, size: 6, mtime: 1_700_000_005, isDir: false, volID: 1)
        let removed = store.append(name: "deleted.txt", parent: root, size: 1, mtime: 1, isDir: false, volID: 1)
        store.markDeleted(removed)
        for row in 0..<extraRows {
            store.append(name: "bulk-\(row).txt", parent: folder, size: UInt64(row), mtime: Int64(row), isDir: false, volID: 1)
        }
        try IndexCache.save(store, to: cache, lastEventID: 71, rulesFingerprint: 93)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func process(_ arguments: [String], stdout: Any? = nil, stderr: Any? = nil, cache selectedCache: URL? = nil) -> Process {
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--cache", (selectedCache ?? cache).path] + arguments
        child.standardOutput = stdout
        child.standardError = stderr
        return child
    }

    func run(_ arguments: [String], cache: URL? = nil, preserveArgumentBytes: Bool = false) throws -> CLIProcessResult {
        let out = directory.appendingPathComponent(UUID().uuidString + ".stdout")
        let err = directory.appendingPathComponent(UUID().uuidString + ".stderr")
        try Data().write(to: out); try Data().write(to: err)
        let stdout = try FileHandle(forWritingTo: out), stderr = try FileHandle(forWritingTo: err)
        defer { try? stdout.close(); try? stderr.close() }
        let child = process(arguments, stdout: stdout, stderr: stderr, cache: cache)
        if preserveArgumentBytes {
            // macOS Foundation.Process converts argv to decomposed filesystem
            // UTF-8. A UTF-8 script's exec preserves exact query bytes, as a shell
            // invocation would, for composed/decomposed Unicode regressions.
            let launcher = directory.appendingPathComponent(UUID().uuidString + ".sh")
            func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let command = ([executable.path] + child.arguments!).map(quoted).joined(separator: " ")
            try Data(("exec " + command + "\n").utf8).write(to: launcher)
            child.executableURL = URL(fileURLWithPath: "/bin/sh")
            child.arguments = [launcher.path]
        }
        try child.run()
        try Self.wait(child)
        return CLIProcessResult(status: child.terminationStatus, stdout: try Data(contentsOf: out), stderr: try Data(contentsOf: err))
    }

    static func wait(_ process: Process) throws {
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw NSError(domain: "CLIProcessFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "CLI process exceeded test deadline"])
        }
        process.waitUntilExit()
    }
}
