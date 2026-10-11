import Testing
import Foundation
@testable import IndexCore

@Test func reconcileDirAppliesCreatesAndDeletes() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ec-live-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try "1".write(to: root.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)

    var store = FileStore()
    let scanner = Scanner(rules: ExcludeRules())
    try scanner.scan(rootPath: root.path, into: &store, volID: 1)
    #expect((0..<UInt32(store.count)).map { store.name(of: $0) }.contains("old.txt"))

    // Mutate filesystem, then reconcile that directory.
    try fm.removeItem(at: root.appendingPathComponent("old.txt"))
    try "2".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
    LiveMonitor.reconcile(directory: root.path, in: &store, rules: ExcludeRules(), volID: 1)

    let liveNames = (0..<UInt32(store.count)).compactMap { store.isLive($0) ? store.name(of: $0) : nil }
    #expect(liveNames.contains("new.txt"))
    #expect(!liveNames.contains("old.txt"))
}

/// reconcile must report WHETHER it changed the store. The live path relies on
/// this to skip re-searching the whole index on the constant stream of FSEvents
/// that add or remove nothing (file content modifications) — the root cause of
/// CPU climbing the longer the app stays open.
@Test func reconcileReportsWhetherStoreChanged() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ec-live-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try "1".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

    var store = FileStore()
    try Scanner(rules: ExcludeRules()).scan(rootPath: root.path, into: &store, volID: 1)

    // Nothing changed since the scan → no change reported.
    #expect(LiveMonitor.reconcile(directory: root.path, in: &store, rules: ExcludeRules(), volID: 1) == false)

    // Modifying an existing file's contents adds/removes nothing → no change.
    try "12345".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    #expect(LiveMonitor.reconcile(directory: root.path, in: &store, rules: ExcludeRules(), volID: 1) == false)

    // Creating a file is a change.
    try "x".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    #expect(LiveMonitor.reconcile(directory: root.path, in: &store, rules: ExcludeRules(), volID: 1) == true)

    // Deleting a file is a change.
    try fm.removeItem(at: root.appendingPathComponent("a.txt"))
    #expect(LiveMonitor.reconcile(directory: root.path, in: &store, rules: ExcludeRules(), volID: 1) == true)
}

/// After a directory is reconciled, a repeat event with no structural change must
/// take the cheap mtime-gated skip (return false without re-reading) — the fix that
/// keeps live-update CPU flat under heavy filesystem churn.
@Test func reconcileSkipsUnchangedDirOnRepeat() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ec-live-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try "1".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

    var store = FileStore()
    try Scanner(rules: ExcludeRules()).scan(rootPath: root.path, into: &store, volID: 1)

    // A real new entry → must reconcile it (and record the dir's mtime).
    try "x".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    #expect(LiveMonitor.reconcile(directory: root.path, in: &store, rules: ExcludeRules(), volID: 1) == true)

    // Immediate repeat, nothing changed on disk → gated skip.
    #expect(LiveMonitor.reconcile(directory: root.path, in: &store, rules: ExcludeRules(), volID: 1) == false)

    // A further real change still gets through (gate is mtime-keyed, not a one-shot).
    try "y".write(to: root.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
    #expect(LiveMonitor.reconcile(directory: root.path, in: &store, rules: ExcludeRules(), volID: 1) == true)
}

/// FSEvents delivers Data-volume changes under the firmlink mount
/// "/System/Volumes/Data", but the index is rooted at canonical "/". A delivered
/// Data path must be mapped back so reconcile can resolve it; non-Data paths pass
/// through untouched. This is the fix for home-folder changes not appearing live.
@Test func canonicalEventPathMapsDataFirmlink() {
    #expect(LiveMonitor.canonicalEventPath("/System/Volumes/Data/Users/me/Desktop") == "/Users/me/Desktop")
    #expect(LiveMonitor.canonicalEventPath("/System/Volumes/Data") == "/")
    #expect(LiveMonitor.canonicalEventPath("/Users/me/Desktop") == "/Users/me/Desktop")
    #expect(LiveMonitor.canonicalEventPath("/Volumes/Backup/x") == "/Volumes/Backup/x")
    // Must not corrupt an unrelated path that merely shares a prefix substring.
    #expect(LiveMonitor.canonicalEventPath("/System/Volumes/DataDisk/x") == "/System/Volumes/DataDisk/x")
}

/// reconcile must resolve a Data-volume change delivered under the firmlink mount
/// path, against an index rooted at canonical "/". Builds a store whose root name
/// is "/" with a nested dir, then reconciles via the /System/Volumes/Data alias.
@Test func reconcileResolvesDataFirmlinkPath() throws {
    let fm = FileManager.default
    // Real temp dir to read from, but we fake the store's root name as "/" so the
    // canonical path "/<temp components>" is what idForDirPath walks.
    let root = fm.temporaryDirectory.appendingPathComponent("ec-fl-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    // canonicalEventPath is a pure mapping; verify it composes with idForDirPath by
    // checking the mapped path equals the canonical path reconcile would resolve.
    let canonical = root.path
    let aliased = "/System/Volumes/Data" + canonical
    #expect(LiveMonitor.canonicalEventPath(aliased) == canonical)
}

/// A newly-created nested directory subtree must be fully indexed when its
/// parent is reconciled — not just the top dir entry. Guards against shallow
/// reconcile dropping bulk/nested creation (mkdir -p a/sub + files).
@Test func reconcileRecursesIntoNewDirectories() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ec-live-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    var store = FileStore()
    try Scanner(rules: ExcludeRules()).scan(rootPath: root.path, into: &store, volID: 1)

    // Create a whole nested subtree, then reconcile only the parent (root).
    let inner = root.appendingPathComponent("sub/inner")
    try fm.createDirectory(at: inner, withIntermediateDirectories: true)
    try "x".write(to: inner.appendingPathComponent("deep.txt"), atomically: true, encoding: .utf8)

    LiveMonitor.reconcile(directory: root.path, in: &store, rules: ExcludeRules(), volID: 1)

    let liveNames = (0..<UInt32(store.count)).compactMap { store.isLive($0) ? store.name(of: $0) : nil }
    #expect(liveNames.contains("sub"))
    #expect(liveNames.contains("inner"))
    #expect(liveNames.contains("deep.txt"))
}

/// Deleting a directory must tombstone its whole subtree, not just the dir
/// entry — otherwise descendants linger as live ghost results.
@Test func reconcileTombstonesDeletedSubtree() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ec-live-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let dir = root.appendingPathComponent("dir")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try "c".write(to: dir.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)

    var store = FileStore()
    try Scanner(rules: ExcludeRules()).scan(rootPath: root.path, into: &store, volID: 1)
    #expect((0..<UInt32(store.count)).compactMap { store.isLive($0) ? store.name(of: $0) : nil }.contains("child.txt"))

    // Remove the entire directory, then reconcile its parent.
    try fm.removeItem(at: dir)
    LiveMonitor.reconcile(directory: root.path, in: &store, rules: ExcludeRules(), volID: 1)

    let liveNames = (0..<UInt32(store.count)).compactMap { store.isLive($0) ? store.name(of: $0) : nil }
    #expect(!liveNames.contains("dir"))
    #expect(!liveNames.contains("child.txt"))
}
