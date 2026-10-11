import Foundation

// A network share the user opted into indexing. Identified by the mount source
// (e.g. "//user@nas._smb._tcp.local/home") rather than the mount point, because
// macOS may remount the same share at a different path ("/Volumes/home-1").
public struct NetworkShare: Sendable, Codable, Equatable, Hashable, Identifiable {
    public let source: String
    public let name: String
    // URL the share can be mounted from again (smb://…), nil when the filesystem
    // type has no known URL form. Saved so the app can reconnect without the user.
    public let url: String?

    public var id: String { source }

    public init(source: String, name: String, url: String? = nil) {
        self.source = source
        self.name = name
        self.url = url
    }

    public init(mount: MountTable.Mount) {
        self.init(source: mount.source, name: (mount.path as NSString).lastPathComponent,
                  url: mount.remountURL)
    }

    // Stable per-share volume id so a share's records can be found and replaced
    // without knowing where it was mounted when they were indexed.
    public var volID: UInt32 {
        var h: UInt32 = 2166136261
        for b in source.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return h <= 1 ? h + 2 : h
    }
}

public enum MountTable {
    public struct Mount: Sendable, Equatable {
        public let path: String
        public let source: String
        public let fsType: String
        public let isLocal: Bool

        public init(path: String, source: String, fsType: String, isLocal: Bool) {
            self.path = path; self.source = source; self.fsType = fsType; self.isLocal = isLocal
        }

        public var remountURL: String? {
            switch fsType {
            case "smbfs": return "smb:" + source
            case "afpfs": return "afp:" + source
            case "nfs":
                guard let colon = source.firstIndex(of: ":") else { return nil }
                return "nfs://" + source[..<colon] + source[source.index(after: colon)...]
            case "webdav": return source
            default: return nil
            }
        }
    }

    // MNT_NOWAIT reads the kernel's cached mount table and never touches the
    // network, so this is safe to call even while a share is stalled.
    public static func mounts() -> [Mount] {
        var mntbuf: UnsafeMutablePointer<statfs>? = nil
        let count = getmntinfo(&mntbuf, MNT_NOWAIT)
        guard count > 0, let mntbuf else { return [] }
        var out: [Mount] = []
        for i in 0..<Int(count) {
            var fs = mntbuf[i]
            let path = withUnsafePointer(to: &fs.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let source = withUnsafePointer(to: &fs.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let fsType = withUnsafePointer(to: &fs.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            out.append(Mount(path: path, source: source, fsType: fsType,
                             isLocal: (fs.f_flags & UInt32(MNT_LOCAL)) != 0))
        }
        return out
    }

    public static func nonLocalMounts() -> [Mount] { mounts().filter { !$0.isLocal } }

    // Shares a user can pick: automounter placeholders (autofs) are non-local too
    // but aren't servers anyone connected to.
    public static func networkMounts() -> [Mount] { nonLocalMounts().filter { $0.fsType != "autofs" } }

    public static func mountPath(forSource source: String) -> String? {
        networkMounts().first { $0.source == source }?.path
    }

    /// The network mount a path lives on, if any (longest mount point wins).
    public static func networkMount(containing path: String) -> Mount? {
        networkMounts()
            .filter { path == $0.path || path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }
}
