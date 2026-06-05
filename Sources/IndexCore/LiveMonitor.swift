import Foundation
import CoreServices

public final class LiveMonitor: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onDirsChanged: ([String]) -> Void

    public init(onDirsChanged: @escaping ([String]) -> Void) {
        self.onDirsChanged = onDirsChanged
    }

    // Re-scan one directory level and apply create/delete diffs against the store.
    public static func reconcile(directory: String, in store: inout FileStore,
                                 rules: ExcludeRules, volID: UInt32) {
        guard let dirID = store.idForDirPath(directory) else { return }
        let existing = store.childIDs(of: dirID)
        var onDisk = Set<String>()
        if let dir = opendir(directory) {
            defer { closedir(dir) }
            while let e = readdir(dir) {
                let name = withUnsafePointer(to: e.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX)) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                let full = (directory as NSString).appendingPathComponent(name)
                if rules.shouldExclude(name: name, path: full, isHidden: name.hasPrefix(".")) { continue }
                onDisk.insert(name)
                if store.childID(named: name, under: dirID) == nil {
                    var st = stat()
                    guard lstat(full, &st) == 0 else { continue }
                    let isDir = (st.st_mode & S_IFMT) == S_IFDIR
                    let newID = store.append(name: name, parent: dirID, size: UInt64(st.st_size),
                                             mtime: Int64(st.st_mtimespec.tv_sec), isDir: isDir, volID: volID)
                    // A newly-created directory can hold a whole subtree that
                    // FSEvents coalesced or reported out of parent-first order.
                    // Index it now so nested/bulk creation is never dropped.
                    if isDir {
                        Scanner(rules: rules).indexContents(of: full, under: newID, into: &store, volID: volID)
                    }
                }
            }
        }
        for id in existing where !onDisk.contains(store.name(of: id)) {
            // Deleting a directory must tombstone its whole subtree, not just the
            // dir entry, or descendants linger as live ghost results.
            markSubtreeDeleted(id, in: &store)
        }
    }

    private static func markSubtreeDeleted(_ id: UInt32, in store: inout FileStore) {
        store.markDeleted(id)
        for child in store.childIDs(of: id) {
            markSubtreeDeleted(child, in: &store)
        }
    }

    public func start(paths: [String],
                      sinceWhen: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)) {
        let info = Unmanaged.passUnretained(self).toOpaque()
        var ctx = FSEventStreamContext(version: 0, info: info, retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            let mon = Unmanaged<LiveMonitor>.fromOpaque(info!).takeUnretainedValue()
            // Valid only because kFSEventStreamCreateFlagUseCFTypes is set below:
            // with that flag eventPaths is a CFArray<CFString>. Without it, paths
            // is a raw char** and this cast reads string bytes as a pointer →
            // SIGSEGV on the first delivered event.
            let cfArray = unsafeBitCast(paths, to: NSArray.self)
            let changed = (0..<count).compactMap { cfArray[$0] as? String }
            mon.onDirsChanged(changed)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagUseCFTypes)
        stream = FSEventStreamCreate(nil, cb, &ctx, paths as CFArray, sinceWhen, 0.3, flags)
        if let s = stream {
            FSEventStreamSetDispatchQueue(s, DispatchQueue(label: "fsevents"))
            FSEventStreamStart(s)
        }
    }

    public func stop() {
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil }
    }
}
