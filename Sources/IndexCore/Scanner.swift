import Foundation
import Darwin

/// Recursively enumerates a directory tree into a FileStore.
/// Uses readdir + fstatat without following symlinks, so symlinked
/// directories are recorded as entries but never recursed into — prevents loops.
public struct Scanner: Sendable {
    public let rules: ExcludeRules

    public init(rules: ExcludeRules) { self.rules = rules }
    struct ScanError: Error {}

    static func normalizedRoot(_ path: String) -> String {
        var root = path
        while root.count > 1 && root.hasSuffix("/") { root.removeLast() }
        return root
    }

    // Open the scan root, then reject symlinks in every indexed component.
    // An initial root can have system aliases (e.g. /var) above its boundary.
    static func openDirectory(_ path: String, relativeTo root: String? = nil) -> UnsafeMutablePointer<DIR>? {
        let options = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var fd: Int32
        if let root, !path.utf8.elementsEqual(root.utf8) {
            let prefix = root == "/" ? "/" : root + "/"
            guard path.utf8.starts(with: prefix.utf8) else { errno = EINVAL; return nil }
            fd = open(root, options)
            guard fd >= 0 else { return nil }
            for bytes in path.utf8.dropFirst(prefix.utf8.count).split(separator: UInt8(47)) {
                let component = String(decoding: bytes, as: UTF8.self)
                guard component != ".", component != ".." else { close(fd); errno = EINVAL; return nil }
                let next = openat(fd, component, options)
                let failure = errno
                close(fd)
                guard next >= 0 else { errno = failure; return nil }
                fd = next
            }
        } else { fd = open(path, options) }
        guard fd >= 0 else { return nil }
        guard let directory = fdopendir(fd) else {
            let failure = errno
            close(fd)
            errno = failure
            return nil
        }
        return directory
    }

    /// Recursively index `rootPath` into `store`. An unreadable root throws before
    /// adding records; unreadable descendants are skipped and mark the scan incomplete.
    public func scan(rootPath: String, into store: inout FileStore, volID: UInt32) throws {
        // Store the root's full absolute path as its name so path(of:) reconstructs
        // absolute paths for every descendant — required for the Path column, opening
        // files, Reveal in Finder, and match-path search. Normalize away a trailing
        // slash except for the volume root "/".
        let rootName = Self.normalizedRoot(rootPath)
        guard let directory = Self.openDirectory(rootName) else { throw ScanError() }
        defer { closedir(directory) }
        var metadata = stat()
        guard fstat(dirfd(directory), &metadata) == 0, metadata.st_size >= 0 else { throw ScanError() }
        // Source: fstat of the opened root directory supplies its size and modification date.
        let rootID = store.append(name: rootName, parent: FileStore.noParent,
                                  size: UInt64(metadata.st_size), mtime: Int64(metadata.st_mtimespec.tv_sec),
                                  isDir: true, volID: volID)
        walk(path: rootName, root: rootName, parent: rootID, into: &store, volID: volID, openedDirectory: directory)
    }

    /// Recursively index the contents of an already-known directory `path` under
    /// an existing `parent` id (the directory entry itself is assumed present).
    /// Used by live reconcile to populate a newly-created subtree.
    @discardableResult
    func indexContents(of path: String, under parent: UInt32, into store: inout FileStore, volID: UInt32) -> Bool {
        guard store.rootID != FileStore.noParent else { return false }
        return walk(path: path, root: store.name(of: store.rootID), parent: parent, into: &store, volID: volID)
    }

    @discardableResult
    private func walk(path: String, root: String, parent: UInt32, into store: inout FileStore, volID: UInt32,
                      openedDirectory: UnsafeMutablePointer<DIR>? = nil) -> Bool {
        guard let dir = openedDirectory ?? Self.openDirectory(path, relativeTo: root) else {
            store.markScanIncomplete(); store.setSubtreeIncomplete(parent, true); return false
        }
        defer { if openedDirectory == nil { closedir(dir) } }

        // First pass: collect names and detect whether this directory is a project
        // root (holds a marker like Cargo.toml/package.json/.git), so the generic
        // marker-scoped dev-folder names are skipped here but not in plain user dirs.
        var names: [String] = []
        var inProjectDir = false
        while true {
            errno = 0
            guard let entp = readdir(dir) else {
                if errno != 0 { store.markScanIncomplete(); store.setSubtreeIncomplete(parent, true); return false }
                break
            }
            // Extract the null-terminated name from the fixed-size d_name tuple.
            let name = withUnsafePointer(to: entp.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX)) {
                    String(cString: $0)
                }
            }
            guard name != "." && name != ".." else { continue }
            names.append(name)
            if ExcludeRules.projectMarkers.contains(name) { inProjectDir = true }
        }

        var completed = true
        for name in names {
            let full = (path as NSString).appendingPathComponent(name)
            let isHidden = name.hasPrefix(".")

            if rules.shouldExclude(name: name, path: full, isHidden: isHidden, inProjectDir: inProjectDir) { continue }

            var st = stat()
            guard fstatat(dirfd(dir), name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_size >= 0 else {
                store.markScanIncomplete(); completed = false; continue
            }

            // lstat reports S_IFLNK for symlinks, not S_IFDIR — so symlinked
            // directories won't be recursed into, preventing infinite loops.
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            // File-name exclude patterns apply to files only (directories are filtered
            // by name/path in shouldExclude above).
            if !isDir && rules.shouldExcludeFile(name: name) { continue }
            let mtime = Int64(st.st_mtimespec.tv_sec)
            let size = UInt64(st.st_size)

            let id = store.append(name: name, parent: parent, size: size,
                                  mtime: mtime, isDir: isDir, volID: volID)
            if isDir {
                if !walk(path: full, root: root, parent: id, into: &store, volID: volID) { completed = false }
            }
        }
        store.setSubtreeIncomplete(parent, !completed)
        return completed
    }
}
