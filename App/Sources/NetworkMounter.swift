import Foundation
import NetFS

// Mounts a share the way Finder's "Connect to Server" does, but silently: no
// dialog is shown, so it only succeeds when the credentials are already in the
// keychain from an earlier manual mount.
enum NetworkMounter {
    static func mount(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        let open = NSMutableDictionary()
        open[kNAUIOptionKey] = kNAUIOptionNoUI
        let mountOptions = NSMutableDictionary()
        var mountpoints: Unmanaged<CFArray>?
        let rc = NetFSMountURLSync(url as CFURL, nil, nil, nil, open, mountOptions, &mountpoints)
        mountpoints?.release()
        return rc == 0
    }
}
