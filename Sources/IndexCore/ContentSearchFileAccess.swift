import Foundation
import Darwin

struct ContentSearchFileStamp: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let flags: UInt32
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(value.st_ctimespec.tv_nsec); flags = value.st_flags
    }
}

/// Descriptor-relative traversal rejects links at every component, including
/// ancestors. All eligibility checks use real filesystem metadata, never stale
/// FileStore size/type values. Descriptor/path identity is rechecked after reads.
final class ContentSearchFileAccess {
    let descriptor: Int32
    let stamp: ContentSearchFileStamp
    private let path: String
    private let allowsNetwork: Bool
    private let maxBytes: Int

    private init(descriptor: Int32, metadata: stat, path: String, allowsNetwork: Bool, maxBytes: Int) {
        self.descriptor = descriptor; stamp = ContentSearchFileStamp(metadata)
        self.path = path; self.allowsNetwork = allowsNetwork; self.maxBytes = maxBytes
    }
    deinit { close(descriptor) }

    static func openFile(path: String, options: ContentSearchOptions,
                         isCancelled: () -> Bool) throws -> ContentSearchFileAccess? {
        guard !isCancelled(), path.hasPrefix("/"), !path.utf8.contains(0),
              options.allowsNetwork || isLocalPath(path) else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !parts.contains("."), !parts.contains("..") else { return nil }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard directory >= 0 else { throw posixError() }
        defer { close(directory) }
        for part in parts.dropLast() {
            guard !isCancelled() else { return nil }
            let next = part.withCString { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
            guard next >= 0 else {
                if errno == ELOOP || errno == ENOTDIR || errno == ENOENT { return nil }
                throw posixError()
            }
            close(directory); directory = next
            guard options.allowsNetwork || isLocalDescriptor(directory) else { return nil }
            var ancestor = stat()
            guard fstat(directory, &ancestor) == 0 else { throw posixError() }
            guard ancestor.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
        }
        guard !isCancelled(), options.allowsNetwork || isLocalDescriptor(directory) else { return nil }
        let name = parts.last!
        var before = stat()
        guard name.withCString({ fstatat(directory, $0, &before, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            throw posixError()
        }
        guard eligible(before, maxBytes: options.maxFileBytes) else { return nil }
        // URL resource values request metadata only, never a ubiquitous download.
        let cloud = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey])
        guard cloud.isUbiquitousItem != true, !isCancelled() else { return nil }
        let descriptor = name.withCString { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOENT { return nil }
            throw posixError()
        }
        var actual = stat()
        guard fstat(descriptor, &actual) == 0 else {
            let error = posixError(); close(descriptor); throw error
        }
        guard !isCancelled(), eligible(actual, maxBytes: options.maxFileBytes),
              ContentSearchFileStamp(before) == ContentSearchFileStamp(actual),
              options.allowsNetwork || isLocalDescriptor(descriptor) else {
            close(descriptor); return nil
        }
        return ContentSearchFileAccess(descriptor: descriptor, metadata: actual, path: path,
                                       allowsNetwork: options.allowsNetwork, maxBytes: options.maxFileBytes)
    }

    func remainsUnchanged(isCancelled: () -> Bool) throws -> Bool {
        guard !isCancelled() else { return false }
        var actual = stat()
        guard fstat(descriptor, &actual) == 0 else { throw Self.posixError() }
        guard ContentSearchFileStamp(actual) == stamp else { return false }
        var options = ContentSearchOptions()
        options.allowsNetwork = allowsNetwork; options.maxFileBytes = maxBytes
        // Re-traverse instead of stat(path): a new ancestor link must not escape
        // to another mount during the post-read identity check.
        guard let current = try Self.openFile(path: path, options: options, isCancelled: isCancelled) else { return false }
        return current.stamp == stamp && !isCancelled()
    }

    private static func eligible(_ value: stat, maxBytes: Int) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_flags & UInt32(SF_DATALESS) == 0
            && value.st_size >= 0 && value.st_size <= maxBytes
    }

    private static func isLocalDescriptor(_ descriptor: Int32) -> Bool {
        var info = statfs()
        return fstatfs(descriptor, &info) == 0 && info.f_flags & UInt32(MNT_LOCAL) != 0
    }

    private static func isLocalPath(_ path: String) -> Bool {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return false }
        defer { free(mounts) }
        var bestLength = -1, local = false
        for index in 0..<Int(count) {
            var mount = mounts[index]
            let root = withUnsafePointer(to: &mount.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let length = root.utf8.count
            if length > bestLength, root == "/" || path == root || path.hasPrefix(root + "/") {
                bestLength = length; local = mount.f_flags & UInt32(MNT_LOCAL) != 0
            }
        }
        return local
    }

    static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
