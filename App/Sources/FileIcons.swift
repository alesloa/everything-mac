import AppKit
import UniformTypeIdentifiers

// Native file-type icons and "Kind" descriptions, resolved from the extension and
// cached so the table can render thousands of recycled rows without re-hitting
// NSWorkspace / re-resolving UTTypes per row. icon(for: UTType) resolves from the
// type registry (no disk I/O), so this stays cheap even while scrolling fast.
// Called only from the table delegate (main thread) — no locking needed.
enum FileIcons {
    // Called from the table delegate (main thread), but a plain static var trips
    // Swift 6 strict-concurrency. The lock makes the caches correct from any
    // thread; nonisolated(unsafe) tells the compiler the lock is the guarantee.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var iconCache: [String: NSImage] = [:]
    nonisolated(unsafe) private static var kindCache: [String: String] = [:]

    // One cache slot per kind: all directories share "\0dir"; files key on their
    // lowercased extension (extensionless files share "").
    private static func key(ext: String, isDir: Bool) -> String { isDir ? "\u{0}dir" : ext }

    private static func utType(ext: String, isDir: Bool) -> UTType {
        if isDir { return .folder }
        if !ext.isEmpty, let t = UTType(filenameExtension: ext) { return t }
        return .data
    }

    static func icon(ext: String, isDir: Bool) -> NSImage {
        let k = key(ext: ext, isDir: isDir)
        lock.lock(); defer { lock.unlock() }
        if let img = iconCache[k] { return img }
        let img = NSWorkspace.shared.icon(for: utType(ext: ext, isDir: isDir))
        img.size = NSSize(width: 16, height: 16)
        iconCache[k] = img
        return img
    }

    static func kind(ext: String, isDir: Bool) -> String {
        let k = key(ext: ext, isDir: isDir)
        lock.lock(); defer { lock.unlock() }
        if let s = kindCache[k] { return s }
        let s: String
        if isDir { s = "Folder" }
        else if ext.isEmpty { s = "File" }
        else if let d = UTType(filenameExtension: ext)?.localizedDescription { s = d }
        else { s = ext.uppercased() + " File" }
        kindCache[k] = s
        return s
    }
}
