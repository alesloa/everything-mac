import Testing
import Foundation
@testable import IndexCore

@Test func scannerIndexesTempTree() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ec-scan-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try "hello".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "world".write(to: root.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)

    var store = FileStore()
    let scanner = Scanner(rules: ExcludeRules())
    try scanner.scan(rootPath: root.path, into: &store, volID: 1)

    let names = (0..<UInt32(store.count)).map { store.name(of: $0) }
    #expect(names.contains("a.txt"))
    #expect(names.contains("b.txt"))
    #expect(names.contains("sub"))
}

@Test func scannerHonorsExcludeRules() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ec-scan-\(UUID().uuidString)")
    try fm.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
    try "x".write(to: root.appendingPathComponent("node_modules/dep.js"), atomically: true, encoding: .utf8)
    try "y".write(to: root.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
    defer { try? fm.removeItem(at: root) }

    var store = FileStore()
    let scanner = Scanner(rules: ExcludeRules(names: ["node_modules"], pathPrefixes: [], excludeHidden: false))
    try scanner.scan(rootPath: root.path, into: &store, volID: 1)

    let names = (0..<UInt32(store.count)).map { store.name(of: $0) }
    #expect(names.contains("keep.txt"))
    #expect(!names.contains("dep.js"))
}

/// Generic dev-folder names (build/target/…) are skipped only inside a directory
/// that also holds a project marker. A "target" next to Cargo.toml is skipped; a
/// standalone "target" folder with no marker is indexed normally.
@Test func scannerMarkerScopesGenericDevFolders() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("ec-scan-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: base) }

    // A real project: Cargo.toml marker + a target/ build dir.
    let project = base.appendingPathComponent("proj")
    try fm.createDirectory(at: project.appendingPathComponent("target"), withIntermediateDirectories: true)
    try "".write(to: project.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)
    try "x".write(to: project.appendingPathComponent("target/artifact.o"), atomically: true, encoding: .utf8)
    try "y".write(to: project.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)

    // A plain user folder that just happens to be named "target", no marker.
    let docs = base.appendingPathComponent("docs")
    try fm.createDirectory(at: docs.appendingPathComponent("target"), withIntermediateDirectories: true)
    try "z".write(to: docs.appendingPathComponent("target/notes.md"), atomically: true, encoding: .utf8)

    var store = FileStore()
    try Scanner(rules: .defaults).scan(rootPath: base.path, into: &store, volID: 1)
    let names = (0..<UInt32(store.count)).map { store.name(of: $0) }

    #expect(names.contains("main.rs"))
    #expect(!names.contains("artifact.o"))  // project's target/ is skipped
    #expect(names.contains("notes.md"))     // standalone target/ is kept
}

/// Verify parent linkage: path(of:) for sub/b.txt ends with "/sub/b.txt".
/// This confirms the parent chain is wired correctly regardless of root name.
@Test func scannerParentLinkage() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ec-scan-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try "world".write(to: root.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)

    var store = FileStore()
    let scanner = Scanner(rules: ExcludeRules())
    try scanner.scan(rootPath: root.path, into: &store, volID: 1)

    // Find the id for "b.txt"
    var bID: UInt32? = nil
    for i in 0..<UInt32(store.count) {
        if store.name(of: i) == "b.txt" { bID = i; break }
    }
    let id = try #require(bID, "b.txt must be indexed")
    let reconstructed = store.path(of: id)
    // Scanner stores the root's full absolute path, so path(of:) is absolute.
    #expect(reconstructed == root.path + "/sub/b.txt", "expected absolute path \(root.path)/sub/b.txt, got \(reconstructed)")
}

@Test func wholeDiskScannerCanDisableStartupDiskWithoutLosingExternalDisks() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("volume-choice-\(UUID().uuidString)")
    defer { try? manager.removeItem(at: root) }
    for path in ["Users", "Volumes/Enabled", "Volumes/Excluded", "Volumes/Network"] {
        let directory = root.appendingPathComponent(path)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([1]).write(to: directory.appendingPathComponent("item.txt"))
    }
    var rules = ExcludeRules(pathPrefixes: [root.path + "/Volumes/Excluded", root.path + "/Volumes/Network"])
    func paths(_ store: FileStore) -> Set<String> {
        Set((0..<UInt32(store.count)).map { store.path(of: $0) })
    }
    let all = ParallelScanner.scanWholeDisk(rules: rules, fileSystemRoot: root.path, isCancelled: { false })
    #expect(paths(all).contains(root.path + "/Users/item.txt"))
    rules.excludeBootVolume = true
    let external = ParallelScanner.scanWholeDisk(rules: rules, fileSystemRoot: root.path + "/", isCancelled: { false })
    #expect(external.scanCompleted && external.path(of: external.rootID) == root.path + "/Volumes")
    #expect(paths(external).contains(root.path + "/Volumes/Enabled/item.txt"))
    #expect(!paths(external).contains(root.path + "/Users/item.txt"))
    #expect(!paths(external).contains(root.path + "/Volumes/Excluded/item.txt"))
    #expect(!paths(external).contains(root.path + "/Volumes/Network/item.txt"))
    // Share scans remain independent of the startup-disk switch.
    let share = ParallelScanner.scan(root: root.path + "/Volumes/Network", rules: ExcludeRules(excludeBootVolume: true),
                                     volID: 2, workers: 2)
    #expect(paths(share).contains(root.path + "/Volumes/Network/item.txt"))
    rules.excludeBootVolume = false
    #expect(paths(ParallelScanner.scanWholeDisk(rules: rules, fileSystemRoot: root.path))
        .contains(root.path + "/Users/item.txt"))
}
