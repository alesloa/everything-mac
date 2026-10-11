import Foundation
import CoreServices

public final class LiveMonitor: @unchecked Sendable {
    // One FSEvents delivery: the directory whose contents changed, plus whether the
    // kernel coalesced so much it could only flag "rescan everything under here"
    // (kFSEventStreamEventFlagMustScanSubDirs) instead of naming the exact level.
    public struct FSChange: Sendable {
        public let path: String
        public let mustScanSubtree: Bool
        public let eventID: UInt64
        public init(path: String, mustScanSubtree: Bool, eventID: UInt64 = 0) {
            self.path = path
            self.mustScanSubtree = mustScanSubtree
            self.eventID = eventID
        }
    }

    // FSEvents owns this context independently of the monitor. A callback already
    // in flight must never dereference a monitor being replaced or deallocated.
    private final class CallbackContext: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        private let onChanged: @Sendable ([FSChange]) -> Void

        init(_ onChanged: @escaping @Sendable ([FSChange]) -> Void) { self.onChanged = onChanged }
        func cancel() { lock.withLock { active = false } }
        func deliver(_ changes: [FSChange]) {
            guard lock.withLock({ active }) else { return }
            onChanged(changes)
        }
    }

    private let lifecycleLock = NSLock()
    private var stream: FSEventStreamRef?
    private var callbackContext: CallbackContext?
    private let onChanged: @Sendable ([FSChange]) -> Void

    public init(onChanged: @escaping @Sendable ([FSChange]) -> Void) {
        self.onChanged = onChanged
    }

    deinit { stop() }

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
        // Grafted network trees are refreshed by their own background scanner.
        // Reject them before stat/opendir can stall the actor on remote I/O.
        guard store.volID(of: dirID) == volID else { return false }

        // Cheap gate: a directory's mtime advances only when its entries are
        // added/removed/renamed, NOT when a file's contents change. Most FSEvents are
        // content modifications (logs, caches, databases), so once we've reconciled a
        // dir, repeat events whose mtime is unchanged skip the expensive readdir+diff.
        // This is what keeps live-update CPU flat under heavy filesystem churn.
        // Nanosecond precision, and nil on a dir's first event (so nothing is missed).
        var dst = stat()
        let haveStat = lstat(directory, &dst) == 0
        let diskMtimeNs = haveStat
            ? Int64(dst.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(dst.st_mtimespec.tv_nsec) : 0
        if haveStat, (dst.st_mode & S_IFMT) == S_IFDIR, store.reconcileMtime(of: dirID) == diskMtimeNs { return false }

        // Children of other volumes (a network share grafted under /Volumes) are
        // managed by their own scan, so only this volume's records are diffed away.
        let allChildren = store.childIDs(of: dirID)
        let existing = allChildren.filter { store.volID(of: $0) == volID }

        guard let dir = Scanner.openDirectory(directory) else {
            // Permission, TCC and transient I/O failures do not prove deletion.
            // Preserve the last-known children and leave the mtime gate unset so
            // a later successful listing can retry without a structural change.
            let failure = errno
            guard failure == ENOENT || failure == ENOTDIR || failure == ELOOP else { return false }
            var changed = false
            for id in existing { store.markSubtreeDeleted(id); changed = true }
            return changed
        }
        defer { closedir(dir) }

        // First pass: names + project-marker detection, so live reconcile applies the
        // SAME marker-scoped exclusion the full scan did (generic names like "build"
        // skipped only inside a project dir).
        var names: [String] = []
        var inProjectDir = false
        while true {
            errno = 0
            guard let e = readdir(dir) else {
                // Never diff away entries using a failed/partial directory read.
                if errno != 0 { return false }
                break
            }
            let name = withUnsafePointer(to: e.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
            if ExcludeRules.projectMarkers.contains(name) { inProjectDir = true }
        }

        // Keep local entries by name; grafted shares are never stat'ed here.
        var existingByName: [String: [UInt32]] = [:]
        for id in existing { existingByName[store.name(of: id), default: []].append(id) }
        let foreignNames = Set(allChildren.filter { store.volID(of: $0) != volID }.map { store.name(of: $0) })
        var onDisk = Set<String>()
        var changed = false, completed = true
        let nonLocalMounts = Set(MountTable.nonLocalMounts().map(\.path))
        for name in names {
            let full = (directory as NSString).appendingPathComponent(name)
            if rules.shouldExclude(name: name, path: full, isHidden: name.hasPrefix("."), inProjectDir: inProjectDir) { continue }
            // Check before lstat: even stat'ing a stalled share can block.
            if foreignNames.contains(name) || nonLocalMounts.contains(full) { onDisk.insert(name); continue }
            var st = stat()
            guard lstat(full, &st) == 0 else {
                onDisk.insert(name); completed = false; continue
            }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            if !isDir && rules.shouldExcludeFile(name: name) { continue }
            onDisk.insert(name)
            if let prior = existingByName[name] {
                if prior.allSatisfy({ store.isDir(of: $0) == isDir }) { continue }
                // A same-name replacement can change file ↔ directory/symlink.
                // Replace its stable slot and tombstone old descendants before
                // adding the new type; content-only changes still do no work.
                for id in prior { store.markSubtreeDeleted(id) }
                changed = true
            }
            let newID = store.append(name: name, parent: dirID, size: UInt64(max(0, st.st_size)),
                                     mtime: Int64(st.st_mtimespec.tv_sec), isDir: isDir, volID: volID)
            changed = true
            if isDir {
                if Scanner(rules: rules).indexContents(of: full, under: newID, into: &store, volID: volID) {
                    newlyIndexedDirs.insert(full)
                } else { completed = false }
            }
        }
        for id in existing where !onDisk.contains(store.name(of: id)) {
            // Deleting a directory must tombstone its whole subtree, not just the
            // dir entry, or descendants linger as live ghost results.
            store.markSubtreeDeleted(id)
            changed = true
        }
        // Remember the mtime we just reconciled at so repeat events for this dir
        // (with the same mtime) take the cheap skip above instead of re-reading it.
        if haveStat && completed { store.setReconcileMtime(dirID, diskMtimeNs) }
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
        for childID in store.childIDs(of: dirID) where store.isDir(of: childID) && store.volID(of: childID) == volID {
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

    public func start(paths: [String],
                      sinceWhen: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        stopLocked()
        let context = CallbackContext(onChanged)
        var ctx = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(context).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                return UnsafeRawPointer(Unmanaged<CallbackContext>.fromOpaque(info).retain().toOpaque())
            },
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackContext>.fromOpaque(info).release()
            }, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, flags, eventIDs in
            guard let info else { return }
            let context = Unmanaged<CallbackContext>.fromOpaque(info).takeUnretainedValue()
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
                changes.append(FSChange(path: p, mustScanSubtree: (flags[i] & mustScan) != 0,
                                        eventID: eventIDs[i]))
            }
            context.deliver(changes)
        }
        // Directory-level events (NOT FileEvents). FSEvents coalesces and reports the
        // DIRECTORY in which something changed rather than emitting one path per
        // changed file — far fewer callbacks under heavy churn, and exactly the
        // granularity reconcile wants (it re-lists a directory and diffs). FileEvents
        // flooded the actor with an event per modified file and handed reconcile file
        // paths it couldn't act on.
        let flags = UInt32(kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, paths as CFArray, sinceWhen, 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue(label: "fsevents"))
        guard FSEventStreamStart(s) else {
            context.cancel()
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return
        }
        stream = s
        callbackContext = context
    }

    public func stop() {
        lifecycleLock.withLock { stopLocked() }
    }

    private func stopLocked() {
        callbackContext?.cancel()
        callbackContext = nil
        guard let s = stream else { return }
        stream = nil
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }
}
