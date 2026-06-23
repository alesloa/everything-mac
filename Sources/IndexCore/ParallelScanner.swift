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

        init(progress: (@Sendable (Int) -> Void)?) { self.progress = progress }

        func appendRoot(name: String) -> UInt32 {
            lock.lock(); defer { lock.unlock() }
            return store.append(name: name, parent: FileStore.noParent,
                                size: 0, mtime: 0, isDir: true, volID: 1)
        }

        // Append all children of `parent`, returning their ids in input order so
        // the caller can pair subdirectory entries with their new ids.
        func appendChildren(_ entries: [Entry], parent: UInt32) -> [UInt32] {
            lock.lock()
            let ids = entries.map {
                store.append(name: $0.name, parent: parent, size: $0.size,
                             mtime: $0.mtime, isDir: $0.isDir, volID: 1)
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

        init(seed: (String, UInt32)) { stack.append(seed) }

        func push(_ items: [(String, UInt32)]) {
            guard !items.isEmpty else { return }
            lock.lock(); stack.append(contentsOf: items); lock.unlock()
        }

        // Claim the next directory, or return nil once the whole tree is done.
        func claim() -> (path: String, parent: UInt32)? {
            while true {
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
                                     progress: (@Sendable (Int) -> Void)? = nil) -> FileStore {
        let builder = Builder(progress: progress)
        let rootID = builder.appendRoot(name: "/")
        let queue = DirQueue(seed: ("/", rootID))

        let workers = max(2, ProcessInfo.processInfo.activeProcessorCount)
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while let (path, parent) = queue.claim() {
                let entries = readDirectory(path, rules: rules)
                let ids = builder.appendChildren(entries, parent: parent)
                var subdirs: [(String, UInt32)] = []
                for (entry, id) in zip(entries, ids) where entry.isDir {
                    subdirs.append((entry.path, id))
                }
                queue.push(subdirs)
                queue.release()
            }
        }
        return builder.finish()
    }

    // One directory level: readdir + lstat each entry, applying exclude rules.
    // lstat (not stat) means symlinked directories are recorded but never
    // descended into, so the firmlink/symlink graph can't create scan loops.
    //
    // Two passes: the first reads names only (no stat) and notes whether this
    // directory holds a project marker (Cargo.toml/package.json/.git/…); the second
    // applies the now-marker-aware exclude rules and stats only the survivors. The
    // marker pass is what lets generic names like "build"/"target" be skipped inside
    // a real project but kept for an unrelated user folder of the same name.
    private static func readDirectory(_ path: String, rules: ExcludeRules) -> [Entry] {
        guard let dir = opendir(path) else { return [] }
        defer { closedir(dir) }
        var names: [String] = []
        var inProjectDir = false
        while let entp = readdir(dir) {
            let name = withUnsafePointer(to: entp.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
            if ExcludeRules.projectMarkers.contains(name) { inProjectDir = true }
        }
        var out: [Entry] = []
        out.reserveCapacity(names.count)
        for name in names {
            let full = path == "/" ? "/" + name : path + "/" + name
            let isHidden = name.hasPrefix(".")
            if rules.shouldExclude(name: name, path: full, isHidden: isHidden, inProjectDir: inProjectDir) { continue }
            var st = stat()
            guard lstat(full, &st) == 0 else { continue }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            out.append(Entry(name: name, path: full, isDir: isDir,
                             size: UInt64(st.st_size), mtime: Int64(st.st_mtimespec.tv_sec)))
        }
        return out
    }
}
