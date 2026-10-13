import Foundation
import Darwin

struct DuplicateFileAccess: Sendable {
    struct Mount: Sendable { let path: String; let local: Bool }
    let options: DuplicateOptions
    private let mounts: [Mount]

    init(options: DuplicateOptions) {
        self.options = DuplicateOptions(allowsNetwork: options.allowsNetwork,
            allowsDownloadedCloudFiles: options.allowsDownloadedCloudFiles,
            workers: options.workers, chunkBytes: options.chunkBytes)
        var table: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&table, MNT_NOWAIT)
        var values: [Mount] = []
        if count > 0, let table {
            defer { free(table) }
            for index in 0..<Int(count) {
                var entry = table[index]
                let path = withUnsafePointer(to: &entry.f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                values.append(Mount(path: path, local: entry.f_flags & UInt32(MNT_LOCAL) != 0))
            }
        }
        mounts = values.sorted { $0.path.utf8.count > $1.path.utf8.count }
    }

    func pathPolicy(_ path: String) -> DuplicateSkipReason? {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            return .unavailable
        }
        guard options.allowsNetwork || mounts.first(where: {
            $0.path == "/" || path.utf8.elementsEqual($0.path.utf8) || path.hasPrefix($0.path + "/")
        })?.local == true else { return .network }
        return nil
    }

    func metadataPolicy(_ metadata: stat, path: String) -> DuplicateSkipReason? {
        let kind = metadata.st_mode & S_IFMT
        if kind == S_IFLNK { return .symbolicLink }
        guard kind == S_IFREG || kind == S_IFDIR else { return .specialFile }
        guard metadata.st_size >= 0 else { return .unavailable }
        guard metadata.st_flags & UInt32(SF_DATALESS) == 0 else { return .cloud }
        guard let values = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]) else { return .unavailable }
        if values.isUbiquitousItem == true {
            guard options.allowsDownloadedCloudFiles,
                  values.ubiquitousItemDownloadingStatus == .current ||
                    values.ubiquitousItemDownloadingStatus == .downloaded else { return .cloud }
        }
        return nil
    }

    func inspect(_ path: String) -> Result<DuplicateFile, AccessFailure> {
        if let reason = pathPolicy(path) { return .failure(AccessFailure(reason: reason)) }
        let parentPath = (path as NSString).deletingLastPathComponent
        guard let parent = openDirectory(parentPath) else { return .failure(AccessFailure(reason: .unavailable)) }
        defer { close(parent) }
        var metadata = stat()
        guard fstatat(parent, (path as NSString).lastPathComponent, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            return .failure(AccessFailure(reason: .unavailable))
        }
        if let reason = metadataPolicy(metadata, path: path) { return .failure(AccessFailure(reason: reason)) }
        guard metadata.st_mode & S_IFMT == S_IFREG else { return .failure(AccessFailure(reason: .specialFile)) }
        return .success(DuplicateFile(path: path, fingerprint: Self.fingerprint(metadata)))
    }

    func openFile(_ file: DuplicateFile) -> Int32? {
        guard pathPolicy(file.path) == nil,
              let parent = openDirectory((file.path as NSString).deletingLastPathComponent) else { return nil }
        defer { close(parent) }
        // NONBLOCK prevents a raced replacement by a FIFO from blocking the worker.
        let descriptor = openat(parent, file.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_flags & UInt32(SF_DATALESS) == 0,
              Self.fingerprint(metadata) == file.fingerprint, descriptorIsAllowed(descriptor) else {
            close(descriptor); return nil
        }
        return descriptor
    }

    func revalidate(_ file: DuplicateFile) -> Bool {
        guard let descriptor = openFile(file) else { return false }
        close(descriptor)
        return true
    }

    // The synthesized opposite-side path is used only for an absence probe;
    // reports display paths that were actually observed during enumeration.
    func absenceIsVerified(_ path: String) -> Bool {
        guard pathPolicy(path) == nil else { return false }
        let parts = path.split(separator: "/")
        guard let name = parts.last else { return false }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var descriptor = open("/", flags)
        guard descriptor >= 0 else { return false }
        for component in parts.dropLast() {
            let next = openat(descriptor, String(component), flags)
            let failure = errno
            close(descriptor)
            if next < 0 { return failure == ENOENT }
            descriptor = next
            guard descriptorIsAllowed(descriptor) else { close(descriptor); return false }
        }
        defer { close(descriptor) }
        var metadata = stat()
        return fstatat(descriptor, String(name), &metadata, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT
    }

    // Every component is opened relative to an already-open directory, refusing
    // symlinks even when an ancestor is replaced between metadata inspection/read.
    func openDirectory(_ path: String) -> Int32? {
        guard pathPolicy(path) == nil else { return nil }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var descriptor = open("/", flags)
        guard descriptor >= 0 else { return nil }
        for component in path.split(separator: "/") {
            let next = openat(descriptor, String(component), flags)
            close(descriptor)
            guard next >= 0 else { return nil }
            descriptor = next
            guard descriptorIsAllowed(descriptor) else { close(descriptor); return nil }
        }
        return descriptor
    }

    func descriptorIsAllowed(_ descriptor: Int32) -> Bool {
        if options.allowsNetwork { return true }
        var metadata = statfs()
        return fstatfs(descriptor, &metadata) == 0 && metadata.f_flags & UInt32(MNT_LOCAL) != 0
    }

    static func fingerprint(_ metadata: stat) -> DuplicateFingerprint {
        DuplicateFingerprint(device: metadata.st_dev, inode: metadata.st_ino, generation: metadata.st_gen,
            mode: metadata.st_mode, size: metadata.st_size,
            modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            changedSeconds: Int64(metadata.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(metadata.st_ctimespec.tv_nsec))
    }

    struct AccessFailure: Error { let reason: DuplicateSkipReason }
}

struct DuplicateInventory: Sendable {
    var files: [DuplicateFile] = []
    var skipped: [DuplicateSkippedFile] = []
    var incomplete = false

    mutating func skip(_ path: String, _ reason: DuplicateSkipReason) {
        skipped.append(DuplicateSkippedFile(path: path, reason: reason))
    }

    static func collect(_ scope: DuplicateScope, access: DuplicateFileAccess,
                        cancellation: DuplicateCancellation, progress: DuplicateProgressReporter) -> Self {
        var inventory = Self()
        guard !cancellation.isCancelled else { return inventory }
        switch scope {
        case .paths(let paths):
            var seen = Set<[UInt8]>()
            for path in paths where seen.insert(Array(path.utf8)).inserted {
                if cancellation.isCancelled { break }
                inventory.inspect(path, access: access, progress: progress)
            }
        case .query(let snapshot, let query, let folderPath):
            inventory.inspectQuery(snapshot: snapshot, query: query, folderPath: folderPath,
                                   access: access, cancellation: cancellation, progress: progress)
        case .scopedQuery(let snapshot, let query, let folderSelection):
            inventory.inspectQuery(snapshot: snapshot, query: query, folderSelection: folderSelection,
                                   access: access, cancellation: cancellation, progress: progress)
        case .folder(let rawPath):
            let path = Scanner.normalizedRoot(rawPath)
            guard let descriptor = access.openDirectory(path) else {
                inventory.skip(path, access.pathPolicy(path) ?? .unavailable)
                inventory.incomplete = true
                return inventory
            }
            var rootMetadata = stat()
            guard fstat(descriptor, &rootMetadata) == 0 else {
                close(descriptor); inventory.skip(path, .unavailable); inventory.incomplete = true; return inventory
            }
            if let reason = access.metadataPolicy(rootMetadata, path: path) {
                close(descriptor); inventory.skip(path, reason); inventory.incomplete = true; return inventory
            }
            inventory.walk(path, descriptor: descriptor, access: access, cancellation: cancellation, progress: progress)
        }
        return inventory
    }

    private mutating func inspectQuery(snapshot: FileStore, query: Query, folderPath: String? = nil,
                                       folderSelection: FolderSearchScope? = nil, access: DuplicateFileAccess,
                                       cancellation: DuplicateCancellation, progress: DuplicateProgressReporter) {
        let candidates: [UInt32]?
        do {
            let resolved = try CatalogNativeScope.resolve(folderPath: folderPath, folderSelection: folderSelection,
                in: snapshot, isCancelled: { cancellation.isCancelled })
            for path in resolved?.missingIncludedPaths ?? [] { skip(path, .unavailable) }
            candidates = try resolved?.candidates(in: snapshot, isCancelled: { cancellation.isCancelled })
        } catch {
            if let folderPath, !cancellation.isCancelled { skip(folderPath, .unavailable) }
            return
        }
        let ids = QueryEngine().search(query.refreshingRelativeDates(), in: snapshot, candidates: candidates,
                                      isCancelled: { cancellation.isCancelled })
        for id in ids {
            if cancellation.isCancelled { break }
            guard !snapshot.isDir(of: id) else { continue }
            inspect(snapshot.path(of: id), access: access, progress: progress)
        }
    }

    private mutating func inspect(_ path: String, access: DuplicateFileAccess,
                                  progress: DuplicateProgressReporter) {
        switch access.inspect(path) {
        case .success(let file): files.append(file); progress.update(.inspecting, inspected: 1)
        case .failure(let failure): skip(path, failure.reason)
        }
    }

    private mutating func walk(_ path: String, descriptor: Int32, access: DuplicateFileAccess,
                              cancellation: DuplicateCancellation, progress: DuplicateProgressReporter) {
        guard let directory = fdopendir(descriptor) else {
            close(descriptor); skip(path, .unavailable); incomplete = true; return
        }
        defer { closedir(directory) }
        while !cancellation.isCancelled {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { skip(path, .unavailable); incomplete = true }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX)) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            let childPath = path == "/" ? "/" + name : path + "/" + name
            var metadata = stat()
            guard fstatat(dirfd(directory), name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                skip(childPath, .unavailable); incomplete = true; continue
            }
            if let reason = access.pathPolicy(childPath) ?? access.metadataPolicy(metadata, path: childPath) {
                skip(childPath, reason)
                if metadata.st_mode & S_IFMT == S_IFDIR { incomplete = true }
                continue
            }
            if metadata.st_mode & S_IFMT == S_IFDIR {
                let child = openat(dirfd(directory), name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                var opened = stat()
                guard child >= 0 else { skip(childPath, .unavailable); incomplete = true; continue }
                guard fstat(child, &opened) == 0, Self.sameDirectory(metadata, opened),
                      access.descriptorIsAllowed(child) else {
                    close(child); skip(childPath, .changed); incomplete = true; continue
                }
                walk(childPath, descriptor: child, access: access, cancellation: cancellation, progress: progress)
            } else {
                files.append(DuplicateFile(path: childPath, fingerprint: DuplicateFileAccess.fingerprint(metadata)))
                progress.update(.inspecting, inspected: 1)
            }
        }
    }

    private static func sameDirectory(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev && left.st_ino == right.st_ino && right.st_mode & S_IFMT == S_IFDIR
    }
}
