import Foundation
import Darwin
import IndexCore

// The path/name come from FileRecord; all eligibility and cache metadata come
// from the mounted filesystem table, lstat and Foundation URL resource values.
struct PreviewFile: Sendable {
    let record: FileRecord
    let url: URL
    let fingerprint: Fingerprint

    struct Fingerprint: Sendable, Hashable {
        let path: [UInt8]
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }
}

enum PreviewFileAccess {
    static func resolve(_ record: FileRecord, allowsNetwork: Bool = false) async -> PreviewFile? {
        let worker = Task.detached(priority: .utility) {
            inspect(record, allowsNetwork: allowsNetwork)
        }
        return await withTaskCancellationHandler {
            let result = await worker.value
            return Task.isCancelled ? nil : result
        } onCancel: { worker.cancel() }
    }

    // This entire probe runs off the main actor. It never opens file contents,
    // requests an iCloud download or invokes a provider for a dataless file.
    static func inspect(_ record: FileRecord, allowsNetwork: Bool) -> PreviewFile? {
        guard !Task.isCancelled, !record.isDir, record.path.hasPrefix("/"),
              !record.path.utf8.contains(0),
              allowsNetwork || isOnLocalMount(record.path) else { return nil }
        var metadata = stat()
        guard record.path.withCString({ lstat($0, &metadata) }) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_flags & UInt32(SF_DATALESS) == 0,
              !Task.isCancelled else { return nil }
        // Refuse symlink ancestors as well: a local-looking path must not reach
        // a remote filesystem or a cloud placeholder through an alternate path.
        var parent = (record.path as NSString).deletingLastPathComponent
        while parent != "/" && !parent.isEmpty {
            var ancestor = stat()
            guard !Task.isCancelled, parent.withCString({ lstat($0, &ancestor) }) == 0,
                  ancestor.st_mode & S_IFMT == S_IFDIR else { return nil }
            parent = (parent as NSString).deletingLastPathComponent
        }
        let url = URL(fileURLWithPath: record.path)
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              !Task.isCancelled else { return nil }
        if values.isUbiquitousItem == true {
            guard values.ubiquitousItemDownloadingStatus == .current ||
                    values.ubiquitousItemDownloadingStatus == .downloaded else { return nil }
        }
        return PreviewFile(record: record, url: url, fingerprint: .init(
            path: Array(record.path.utf8), device: metadata.st_dev, inode: metadata.st_ino,
            size: metadata.st_size, modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec)))
    }

    private static func isOnLocalMount(_ path: String) -> Bool {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return false }
        defer { free(mounts) }
        var bestLength = -1
        var local = false
        for index in 0..<Int(count) {
            var mount = mounts[index]
            let root = withUnsafePointer(to: &mount.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let bytes = root.utf8.count
            if bytes > bestLength, root == "/" || path == root || path.hasPrefix(root + "/") {
                bestLength = bytes
                local = mount.f_flags & UInt32(MNT_LOCAL) != 0
            }
        }
        return local
    }
}
