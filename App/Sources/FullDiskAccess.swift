import Foundation
import AppKit

enum FullDiskAccess {
    // Reliable probe: the TCC database is readable ONLY by an app with Full Disk
    // Access. Opening it for reading performs the protected open() that TCC gates,
    // so a non-FDA app gets nil here. (The old ~/Library/Mail check false-positived
    // when Mail was never set up, hiding the banner while the scan silently skipped
    // protected paths and other volumes.)
    static func isGranted() -> Bool {
        let candidates = [
            "Library/Application Support/com.apple.TCC/TCC.db",
            "Library/Safari/Bookmarks.plist",
        ].map { (NSHomeDirectory() as NSString).appendingPathComponent($0) }

        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let fh = FileHandle(forReadingAtPath: path) {
                fh.closeFile()
                return true
            }
            return false // file exists but open() denied → FDA not granted
        }
        // None of the probe files exist (unusual). Don't nag with a false banner.
        return true
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}
