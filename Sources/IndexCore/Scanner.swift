import Foundation

/// Recursively enumerates a directory tree into a FileStore.
/// Uses readdir + lstat: lstat does not follow symlinks, so symlinked
/// directories are recorded as entries but never recursed into — prevents loops.
public struct Scanner: Sendable {
    public let rules: ExcludeRules

    public init(rules: ExcludeRules) { self.rules = rules }

    /// Recursively index `rootPath` into `store`. Root is added first, then descendants.
    public func scan(rootPath: String, into store: inout FileStore, volID: UInt32) throws {
        // Store the root's full absolute path as its name so path(of:) reconstructs
        // absolute paths for every descendant — required for the Path column, opening
        // files, Reveal in Finder, and match-path search. Normalize away a trailing
        // slash except for the volume root "/".
        let rootName = rootPath == "/" ? "/" : (rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath)
        let rootID = store.append(name: rootName, parent: FileStore.noParent,
                                  size: 0, mtime: 0, isDir: true, volID: volID)
        walk(path: rootPath, parent: rootID, into: &store, volID: volID)
    }

    /// Recursively index the contents of an already-known directory `path` under
    /// an existing `parent` id (the directory entry itself is assumed present).
    /// Used by live reconcile to populate a newly-created subtree.
    func indexContents(of path: String, under parent: UInt32, into store: inout FileStore, volID: UInt32) {
        walk(path: path, parent: parent, into: &store, volID: volID)
    }

    private func walk(path: String, parent: UInt32, into store: inout FileStore, volID: UInt32) {
        guard let dir = opendir(path) else { return }
        defer { closedir(dir) }

        // First pass: collect names and detect whether this directory is a project
        // root (holds a marker like Cargo.toml/package.json/.git), so the generic
        // marker-scoped dev-folder names are skipped here but not in plain user dirs.
        var names: [String] = []
        var inProjectDir = false
        while let entp = readdir(dir) {
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

        for name in names {
            let full = (path as NSString).appendingPathComponent(name)
            let isHidden = name.hasPrefix(".")

            if rules.shouldExclude(name: name, path: full, isHidden: isHidden, inProjectDir: inProjectDir) { continue }

            var st = stat()
            guard lstat(full, &st) == 0 else { continue }

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
                walk(path: full, parent: id, into: &store, volID: volID)
            }
        }
    }
}
