import Foundation

// Whole-disk scanner that walks the tree with a pool of worker threads pulling
// from a shared directory work-queue. Replaces the old single-threaded async
// recursion that ran on the IndexActor: that walk paid continuation overhead per
// directory and, worse, contended with searches re-sorting the growing index on
// every progress tick. This runs entirely off the actor and saturates all cores,
// taking a whole-disk scan from minutes to tens of seconds.
public enum ParallelScanner {

    // Mutable index shared by all workers, guarded by one lock. The lock is held
    // only to append a directory's already-stat'd entries (a memory-only burst);
    // the expensive readdir/lstat happens outside it, so contention stays low.
    final class Builder: @unchecked Sendable {
        private var store = FileStore()
        private let lock = NSLock()
        private var lastReported = 0
        private let progress: (@Sendable (Int) -> Void)?
        private let volID: UInt32

        init(volID: UInt32, progress: (@Sendable (Int) -> Void)?) {
            self.volID = volID
            self.progress = progress
        }

        func appendRoot(name: String, size: UInt64, mtime: Int64) -> UInt32 {
            lock.lock(); defer { lock.unlock() }
            return store.append(name: name, parent: FileStore.noParent,
                                size: size, mtime: mtime, isDir: true, volID: volID)
        }

        // Append all children of `parent`, returning their ids in input order so
        // the caller can pair subdirectory entries with their new ids.
        func markIncomplete(_ parent: UInt32) {
            lock.withLock {
                store.markScanIncomplete()
                store.setSubtreeIncomplete(parent, true)
            }
        }

        func appendChildren(_ entries: [Entry], parent: UInt32,
                            isCancelled: @Sendable () -> Bool) -> [UInt32] {
            lock.lock()
            var ids: [UInt32] = []
            ids.reserveCapacity(entries.count)
            for (offset, entry) in entries.enumerated() {
                if offset & 1023 == 0 && isCancelled() { break }
                ids.append(store.append(name: entry.name, parent: parent, size: entry.size,
                                        mtime: entry.mtime, isDir: entry.isDir, volID: volID))
            }
            let count = store.count
            let crossed = count / 50_000 != lastReported / 50_000
            lastReported = count
            lock.unlock()
            if crossed { progress?(count) }
            return ids
        }

        func finish() -> FileStore {
            lock.lock(); defer { lock.unlock() }
            return store
        }
    }

    struct Entry { let name: String; let path: String; let isDir: Bool; let size: UInt64; let mtime: Int64 }

    // Lock-protected work stack with active-worker accounting so a worker only
    // concludes the scan is finished when the stack is empty AND no peer is still
    // mid-directory (and could yet push more subdirectories).
    final class DirQueue: @unchecked Sendable {
        private var stack: [(path: String, parent: UInt32)] = []
        private let lock = NSLock()
        private var active = 0

        init(seed: [(String, UInt32)]) { stack = seed }

        func push(_ items: [(String, UInt32)]) {
            guard !items.isEmpty else { return }
            lock.lock(); stack.append(contentsOf: items); lock.unlock()
        }

        // Claim the next directory, or return nil once the whole tree is done.
        func claim(isCancelled: @Sendable () -> Bool) -> (path: String, parent: UInt32)? {
            while true {
                if isCancelled() { return nil }
                lock.lock()
                if let item = stack.popLast() { active += 1; lock.unlock(); return item }
                if active == 0 { lock.unlock(); return nil }   // empty + nobody working → done
                lock.unlock()
                usleep(200)                                    // peers may still push
            }
        }

        func release() { lock.lock(); active -= 1; lock.unlock() }
    }

    /// Scan the entire filesystem from "/" and return a single FileStore.
    /// `rules` should already include the firmlink back-door exclusions so the
    /// Data volume isn't counted twice. Blocks the calling thread until complete,
    /// so call it from a detached task, never on the actor.
    public static func scanWholeDisk(rules: ExcludeRules,
                                     isCancelled: @escaping @Sendable () -> Bool = { false },
                                     progress: (@Sendable (Int) -> Void)? = nil) -> FileStore {
        scan(root: "/", rules: rules, volID: 1,
             workers: max(2, ProcessInfo.processInfo.activeProcessorCount), isCancelled: isCancelled, progress: progress)
    }

    /// Scan one directory tree into its own FileStore, rooted at `root` (stored as
    /// the root record's name so paths come out absolute). `workers` is capped by
    /// the caller: a network share wants a few parallel readers, not every core.
    /// Cancellation or an unreadable root returns an empty store. Descendant read
    /// failures retain the readable portion and set `scanCompleted` to false.
    public static func scan(root: String, rules: ExcludeRules, volID: UInt32, workers: Int,
                            isCancelled: @escaping @Sendable () -> Bool = { false },
                            progress: (@Sendable (Int) -> Void)? = nil) -> FileStore {
        guard !isCancelled() else { return FileStore() }
        let rootName = Scanner.normalizedRoot(root)
        guard let rootEntries = readDirectory(rootName, root: rootName, rules: rules, isCancelled: isCancelled),
              let metadata = rootEntries.rootMetadata else { return FileStore() }
        let builder = Builder(volID: volID, progress: progress)
        let rootID = builder.appendRoot(name: rootName, size: metadata.size, mtime: metadata.mtime)
        if rootEntries.incomplete { builder.markIncomplete(rootID) }
        let ids = builder.appendChildren(rootEntries.entries, parent: rootID, isCancelled: isCancelled)
        let initial = zip(rootEntries.entries, ids).filter { $0.0.isDir }.map { ($0.0.path, $0.1) }
        let queue = DirQueue(seed: initial)

        DispatchQueue.concurrentPerform(iterations: max(1, workers)) { _ in
            while let (path, parent) = queue.claim(isCancelled: isCancelled) {
                guard let listing = readDirectory(path, root: rootName, rules: rules, isCancelled: isCancelled) else {
                    builder.markIncomplete(parent); queue.release(); continue
                }
                if listing.incomplete { builder.markIncomplete(parent) }
                let entries = listing.entries
                let ids = builder.appendChildren(entries, parent: parent, isCancelled: isCancelled)
                var subdirs: [(String, UInt32)] = []
                for (entry, id) in zip(entries, ids) where entry.isDir {
                    subdirs.append((entry.path, id))
                }
                queue.push(subdirs)
                queue.release()
            }
        }
        return isCancelled() ? FileStore() : builder.finish()
    }

    // One directory level: readdir + fstatat each entry, applying exclude rules.
    // AT_SYMLINK_NOFOLLOW means symlinked directories are recorded but never
    // descended into, so the firmlink/symlink graph can't create scan loops.
    //
    // Two passes: the first reads names only (no stat) and notes whether this
    // directory holds a project marker (Cargo.toml/package.json/.git/…); the second
    // applies the now-marker-aware exclude rules and stats only the survivors. The
    // marker pass is what lets generic names like "build"/"target" be skipped inside
    // a real project but kept for an unrelated user folder of the same name.
    private static func readDirectory(_ path: String, root: String, rules: ExcludeRules,
                                      isCancelled: @Sendable () -> Bool)
        -> (entries: [Entry], incomplete: Bool, rootMetadata: (size: UInt64, mtime: Int64)?)? {
        guard !isCancelled(), let dir = Scanner.openDirectory(path, relativeTo: root) else { return nil }
        defer { closedir(dir) }
        var rootMetadata: (size: UInt64, mtime: Int64)?
        if path.utf8.elementsEqual(root.utf8) {
            var metadata = stat()
            guard fstat(dirfd(dir), &metadata) == 0, metadata.st_size >= 0 else { return nil }
            rootMetadata = (UInt64(metadata.st_size), Int64(metadata.st_mtimespec.tv_sec))
        }
        var names: [String] = []
        var inProjectDir = false
        while true {
            if names.count & 1023 == 0 && isCancelled() { return nil }
            errno = 0
            guard let entp = readdir(dir) else {
                if errno != 0 { return nil }
                break
            }
            let name = withUnsafePointer(to: entp.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
            if ExcludeRules.projectMarkers.contains(name) { inProjectDir = true }
        }
        var out: [Entry] = []
        out.reserveCapacity(names.count)
        var incomplete = false
        for (offset, name) in names.enumerated() {
            if offset & 1023 == 0 && isCancelled() { return nil }
            let full = path == "/" ? "/" + name : path + "/" + name
            let isHidden = name.hasPrefix(".")
            if rules.shouldExclude(name: name, path: full, isHidden: isHidden, inProjectDir: inProjectDir) { continue }
            var st = stat()
            guard fstatat(dirfd(dir), name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_size >= 0 else {
                incomplete = true; continue
            }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            // File-name exclude patterns apply to files only.
            if !isDir && rules.shouldExcludeFile(name: name) { continue }
            out.append(Entry(name: name, path: full, isDir: isDir,
                             size: UInt64(st.st_size), mtime: Int64(st.st_mtimespec.tv_sec)))
        }
        return (out, incomplete, rootMetadata)
    }
}
