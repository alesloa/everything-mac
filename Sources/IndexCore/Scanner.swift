import Foundation
import Darwin

/// Recursively enumerates a directory tree into a FileStore.
/// Uses readdir + lstat: lstat does not follow symlinks, so symlinked
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

    // Never follow a directory replaced by a symlink between lstat and descent.
    static func openDirectory(_ path: String) -> UnsafeMutablePointer<DIR>? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
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
        let rootID = store.append(name: rootName, parent: FileStore.noParent,
                                  size: 0, mtime: 0, isDir: true, volID: volID)
        walk(path: rootName, parent: rootID, into: &store, volID: volID, openedDirectory: directory)
    }

    /// Recursively index the contents of an already-known directory `path` under
    /// an existing `parent` id (the directory entry itself is assumed present).
    /// Used by live reconcile to populate a newly-created subtree.
    @discardableResult
    func indexContents(of path: String, under parent: UInt32, into store: inout FileStore, volID: UInt32) -> Bool {
        walk(path: path, parent: parent, into: &store, volID: volID)
    }

    @discardableResult
    private func walk(path: String, parent: UInt32, into store: inout FileStore, volID: UInt32,
                      openedDirectory: UnsafeMutablePointer<DIR>? = nil) -> Bool {
        guard let dir = openedDirectory ?? Self.openDirectory(path) else { store.markScanIncomplete(); return false }
        defer { if openedDirectory == nil { closedir(dir) } }

        // First pass: collect names and detect whether this directory is a project
        // root (holds a marker like Cargo.toml/package.json/.git), so the generic
        // marker-scoped dev-folder names are skipped here but not in plain user dirs.
        var names: [String] = []
        var inProjectDir = false
        while true {
            errno = 0
            guard let entp = readdir(dir) else {
                if errno != 0 { store.markScanIncomplete(); return false }
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
            guard lstat(full, &st) == 0 else { store.markScanIncomplete(); completed = false; continue }

            // lstat reports S_IFLNK for symlinks, not S_IFDIR — so symlinked
            // directories won't be recursed into, preventing infinite loops.
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            // File-name exclude patterns apply to files only (directories are filtered
            // by name/path in shouldExclude above).
            if !isDir && rules.shouldExcludeFile(name: name) { continue }
            let mtime = Int64(st.st_mtimespec.tv_sec)
            let size = UInt64(max(0, st.st_size))

            let id = store.append(name: name, parent: parent, size: size,
                                  mtime: mtime, isDir: isDir, volID: volID)
            if isDir {
                if !walk(path: full, parent: id, into: &store, volID: volID) { completed = false }
            }
        }
        return completed
    }
}
