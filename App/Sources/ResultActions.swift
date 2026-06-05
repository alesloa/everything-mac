import AppKit
import IndexCore

enum ResultActions {
    static func open(_ rec: FileRecord) { NSWorkspace.shared.open(URL(fileURLWithPath: rec.path)) }
    static func open(_ rec: FileRecord, with appURL: URL) {
        NSWorkspace.shared.open([URL(fileURLWithPath: rec.path)],
                                withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }
    static func reveal(_ rec: FileRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rec.path)])
    }
    static func copyPath(_ rec: FileRecord) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(rec.path, forType: .string)
    }
    static func copyName(_ rec: FileRecord) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(rec.name, forType: .string)
    }
    static func trash(_ rec: FileRecord) {
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: rec.path), resultingItemURL: nil)
    }
}
