import Testing
import Foundation
@testable import IndexCore

@Test func networkTreeMergePreservesPathsAndVolumeIsolation() throws {
    var store = FileStore()
    let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    let volumes = store.append(name: "Volumes", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
    let local = store.append(name: "local.txt", parent: root, size: 1, mtime: 0, isDir: false, volID: 1)
    var sub = FileStore()
    let subRoot = sub.append(name: "/Volumes/share", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 2)
    sub.append(name: "nested.txt", parent: subRoot, size: 42, mtime: 7, isDir: false, volID: 2)

    let merged = store.merge(sub, asChildOf: volumes, volID: 2)
    let graft = try #require(merged)
    let file = try #require(store.childID(named: "nested.txt", under: graft))
    #expect(store.path(of: file) == "/Volumes/share/nested.txt")
    #expect(store.size(of: file) == 42)
    #expect(store.liveCount(volID: 2) == 2)
    let removed = store.markDeleted(volID: 2)
    #expect(removed == 2)
    #expect(store.liveCount(volID: 2) == 0)
    #expect(store.isLive(local))
    #expect(store.isLive(volumes))
}

@Test func scopedParallelScanHonorsFileExclusions() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ec-network-\(UUID().uuidString)")
    try fm.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try Data().write(to: root.appendingPathComponent("nested/keep.txt"))
    try Data().write(to: root.appendingPathComponent("nested/skip.tmp"))

    let store = ParallelScanner.scan(root: root.path, rules: ExcludeRules(excludeFilePatterns: ["*.tmp"]),
                                     volID: 2, workers: 4)
    let paths = (0..<UInt32(store.count)).map { store.path(of: $0) }
    #expect(paths.contains(root.appendingPathComponent("nested/keep.txt").path))
    #expect(!paths.contains(root.appendingPathComponent("nested/skip.tmp").path))
    #expect(store.liveCount(volID: 2) == store.count)
}

@Test func localReconcileKeepsOfflineShareAndSkipsItsSubtree() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ec-network-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    var store = FileStore()
    let parent = store.append(name: root.path, parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    let share = store.append(name: "offline-share", parent: parent, size: 0, mtime: 0, isDir: true, volID: 2)
    let file = store.append(name: "cached.txt", parent: share, size: 1, mtime: 0, isDir: false, volID: 2)
    var newlyIndexed = Set<String>()
    var stack: [String] = []

    let changed = LiveMonitor.reconcileLevel(directory: root.path, in: &store, rules: ExcludeRules(),
        volID: 1, descend: true, newlyIndexedDirs: &newlyIndexed, pushChildDirsTo: &stack)
    #expect(!changed)
    #expect(store.isLive(share))
    #expect(store.isLive(file))
    #expect(stack.isEmpty)
}

@Test func localReconcileDoesNotReadAnotherVolume() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ec-network-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try Data().write(to: root.appendingPathComponent("new.txt"))
    var store = FileStore()
    store.append(name: root.path, parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 2)
    #expect(!LiveMonitor.reconcile(directory: root.path, in: &store, rules: ExcludeRules(), volID: 1))
    #expect(store.count == 1)
}

@Test func defaultRulesKeepPreNetworkCacheFingerprint() {
    // Fingerprint of ExcludeRules.defaults from main at bb178c4, before network shares.
    #expect(ExcludeRules.defaults.fingerprint() == 5_371_999_411_695_464_081)
}

@Test func configuredSharesRoundTripAndInvalidateRulesFingerprint() throws {
    var rules = ExcludeRules.defaults
    let original = rules.fingerprint()
    rules.networkShares = [NetworkShare(source: "//user@nas/share", name: "share", url: "smb://user@nas/share")]
    let decoded = try JSONDecoder().decode(ExcludeRules.self, from: JSONEncoder().encode(rules))
    #expect(decoded == rules)
    #expect(decoded.fingerprint() != original)
    #expect(decoded.networkShares[0].volID > 1)
}

@Test func networkShareIdentitySurvivesMountPathChanges() {
    let first = MountTable.Mount(path: "/Volumes/share", source: "//user@nas/share", fsType: "smbfs", isLocal: false)
    let second = MountTable.Mount(path: "/Volumes/share-1", source: first.source, fsType: first.fsType, isLocal: false)
    #expect(NetworkShare(mount: first).id == NetworkShare(mount: second).id)
    #expect(NetworkShare(mount: first).volID == NetworkShare(mount: second).volID)
    #expect(first.remountURL == "smb://user@nas/share")
}
