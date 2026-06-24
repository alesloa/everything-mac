import Foundation
import CoreServices

public final class LiveMonitor: @unchecked Sendable {
    // One FSEvents delivery: the directory whose contents changed, plus whether the
    // kernel coalesced so much it could only flag "rescan everything under here"
    // (kFSEventStreamEventFlagMustScanSubDirs) instead of naming the exact level.
    public struct FSChange: Sendable {
        public let path: String
        public let mustScanSubtree: Bool
        public init(path: String, mustScanSubtree: Bool) {
            self.path = path
            self.mustScanSubtree = mustScanSubtree
        }
    }

    private var stream: FSEventStreamRef?
    private let onChanged: ([FSChange]) -> Void

    public init(onChanged: @escaping ([FSChange]) -> Void) {
        self.onChanged = onChanged
    }

    // Re-scan one directory level and apply create/delete diffs against the store.
    // Returns whether anything was actually added or removed: the live path uses this
    // to avoid re-searching the whole index on the constant stream of FSEvents that
    // change nothing structural (file content modifications) — the difference between
    // a flat idle cost and CPU that climbs the longer the app is open.
    //
    // `newlyIndexedDirs` collects the paths of brand-new directory subtrees indexed in
    // this pass (via indexContents). The batch driver uses it to skip re-listing a
    // subtree a sibling event in the same batch already built.
    @discardableResult
    public static func reconcile(directory: String, in store: inout FileStore,
                                 rules: ExcludeRules, volID: UInt32,
                                 newlyIndexedDirs: inout Set<String>) -> Bool {
        guard let dirID = store.idForDirPath(directory) else { return false }

        // Cheap gate: a directory's mtime advances only when its entries are
        // added/removed/renamed, NOT when a file's contents change. Most FSEvents are
        // content modifications (logs, caches, databases), so once we've reconciled a
        // dir, repeat events whose mtime is unchanged skip the expensive readdir+diff.
        // This is what keeps live-update CPU flat under heavy filesystem churn.
        // Nanosecond precision, and nil on a dir's first event (so nothing is missed).
        var dst = stat()
        let haveStat = stat(directory, &dst) == 0
        let diskMtimeNs = haveStat
            ? Int64(dst.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(dst.st_mtimespec.tv_nsec) : 0
        if haveStat, store.reconcileMtime(of: dirID) == diskMtimeNs { return false }

        let existing = store.childIDs(of: dirID)

        guard let dir = opendir(directory) else {
            // The directory itself is gone — tombstone whatever children remain.
            var changed = false
            for id in existing { markSubtreeDeleted(id, in: &store); changed = true }
            return changed
        }
        defer { closedir(dir) }

        // First pass: names + project-marker detection, so live reconcile applies the
        // SAME marker-scoped exclusion the full scan did (generic names like "build"
        // skipped only inside a project dir).
        var names: [String] = []
        var inProjectDir = false
        while let e = readdir(dir) {
            let name = withUnsafePointer(to: e.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
            if ExcludeRules.projectMarkers.contains(name) { inProjectDir = true }
        }

        // Live child names as a Set so the per-entry "is this new?" check below is O(1).
        // childID(named:) is a linear scan that decodes a String per comparison, i.e.
        // O(entries · children) per reconcile — quadratic, which pegged a core when a
        // big, busy directory (a browser cache with thousands of files) reconciled on
        // every add/remove. Building one Set makes the whole diff O(entries + children).
        var existingNames = Set<String>(minimumCapacity: existing.count)
        for id in existing { existingNames.insert(store.name(of: id)) }

        var onDisk = Set<String>()
        var changed = false
        for name in names {
            let full = (directory as NSString).appendingPathComponent(name)
            if rules.shouldExclude(name: name, path: full, isHidden: name.hasPrefix("."), inProjectDir: inProjectDir) { continue }
            onDisk.insert(name)
            if !existingNames.contains(name) {
                var st = stat()
                guard lstat(full, &st) == 0 else { continue }
                let isDir = (st.st_mode & S_IFMT) == S_IFDIR
                // File-name exclude patterns apply to files only — a newly created
                // file matching e.g. "*.tmp" must stay out of the live index too.
                if !isDir && rules.shouldExcludeFile(name: name) { continue }
                let newID = store.append(name: name, parent: dirID, size: UInt64(st.st_size),
                                         mtime: Int64(st.st_mtimespec.tv_sec), isDir: isDir, volID: volID)
                changed = true
                // A newly-created directory can hold a whole subtree that FSEvents
                // coalesced or reported out of parent-first order. Index it now so
                // nested/bulk creation is never dropped, and record it so a sibling
                // event for the same subtree this batch doesn't re-list it.
                if isDir {
                    Scanner(rules: rules).indexContents(of: full, under: newID, into: &store, volID: volID)
                    newlyIndexedDirs.insert(full)
                }
            }
        }
        for id in existing where !onDisk.contains(store.name(of: id)) {
            // Deleting a directory must tombstone its whole subtree, not just the
            // dir entry, or descendants linger as live ghost results.
            markSubtreeDeleted(id, in: &store)
            changed = true
        }
        // Remember the mtime we just reconciled at so repeat events for this dir
        // (with the same mtime) take the cheap skip above instead of re-reading it.
        if haveStat { store.setReconcileMtime(dirID, diskMtimeNs) }
        return changed
    }

    // Convenience for callers that don't track cross-call subtree dedup (tests, one-off
    // reconciles): reconcile a single directory level.
    @discardableResult
    public static func reconcile(directory: String, in store: inout FileStore,
                                 rules: ExcludeRules, volID: UInt32) -> Bool {
        var ignored = Set<String>()
        return reconcile(directory: directory, in: &store, rules: rules, volID: volID, newlyIndexedDirs: &ignored)
    }

    // Reconcile a single directory level. When the caller is descending a subtree — the
    // FSEvents MustScanSubDirs overflow flag, where the kernel only says "something under
    // here changed" without naming the leaf — append the live child directories to `stack`
    // so the caller visits them next. The caller (IndexActor) drives the descent with an
    // explicit stack and an `await` between levels, so a deep resync NEVER holds the actor
    // in one uninterruptible call the way a recursive walk did: a queued search interleaves
    // throughout. `newlyIndexedDirs` carries across the whole descent so a subtree just
    // fully built (a new dir → indexContents) isn't re-listed.
    @discardableResult
    public static func reconcileLevel(directory: String, in store: inout FileStore,
                                      rules: ExcludeRules, volID: UInt32, descend: Bool,
                                      newlyIndexedDirs: inout Set<String>,
                                      pushChildDirsTo stack: inout [String]) -> Bool {
        let changed = reconcile(directory: directory, in: &store, rules: rules, volID: volID,
                                newlyIndexedDirs: &newlyIndexedDirs)
        guard descend, let dirID = store.idForDirPath(directory) else { return changed }
        // Snapshot of live child dirs after reconcile (includes any just appended).
        for childID in store.childIDs(of: dirID) where store.isDir(of: childID) {
            let childPath = store.path(of: childID)
            // A subtree just fully indexed (new dir → indexContents) is already current.
            if newlyIndexedDirs.contains(where: { childPath == $0 || childPath.hasPrefix($0 + "/") }) { continue }
            stack.append(childPath)
        }
        return changed
    }

    // FSEvents reports changes on the Data volume under its firmlink mount point
    // "/System/Volumes/Data", but the whole-disk index is rooted at the canonical
    // "/" (the Data volume's content appears directly under / via firmlinks, and the
    // scan deliberately skips the /System/Volumes/Data back-door to avoid double
    // indexing). Map a delivered Data-volume path back to its canonical form so
    // reconcile can resolve it against the store. Non-Data paths pass through.
    public static func canonicalEventPath(_ path: String) -> String {
        let alias = "/System/Volumes/Data"
        if path == alias { return "/" }
        if path.hasPrefix(alias + "/") { return String(path.dropFirst(alias.count)) }
        return path
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
        let cb: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            let mon = Unmanaged<LiveMonitor>.fromOpaque(info!).takeUnretainedValue()
            // Valid only because kFSEventStreamCreateFlagUseCFTypes is set below:
            // with that flag eventPaths is a CFArray<CFString>. Without it, paths
            // is a raw char** and this cast reads string bytes as a pointer →
            // SIGSEGV on the first delivered event.
            let cfArray = unsafeBitCast(paths, to: NSArray.self)
            let mustScan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
            var changes: [FSChange] = []
            changes.reserveCapacity(count)
            for i in 0..<count {
                guard let p = cfArray[i] as? String else { continue }
                changes.append(FSChange(path: p, mustScanSubtree: (flags[i] & mustScan) != 0))
            }
            mon.onChanged(changes)
        }
        // Directory-level events (NOT FileEvents). FSEvents coalesces and reports the
        // DIRECTORY in which something changed rather than emitting one path per
        // changed file — far fewer callbacks under heavy churn, and exactly the
        // granularity reconcile wants (it re-lists a directory and diffs). FileEvents
        // flooded the actor with an event per modified file and handed reconcile file
        // paths it couldn't act on.
        let flags = UInt32(kFSEventStreamCreateFlagNoDefer
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
