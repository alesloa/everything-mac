import AppKit
import IndexCore
import UniformTypeIdentifiers

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

    // Write the current result list to a tab-separated file the user picks. TSV (not
    // CSV) because paths rarely contain tabs but routinely contain commas/quotes that
    // would need escaping; sizes are raw bytes so the file stays script-friendly.
    static func exportResults(_ rows: [FileRecord]) {
        let panel = NSSavePanel()
        panel.title = "Export Results"
        panel.nameFieldStringValue = "EverythingMac-results.tsv"
        panel.allowedContentTypes = [.tabSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var out = "Name\tPath\tSize\tKind\tDate Modified\n"
        for r in rows {
            let ext = (r.name as NSString).pathExtension.lowercased()
            let size = r.isDir ? "" : String(r.size)
            let kind = FileIcons.kind(ext: ext, isDir: r.isDir)
            let date = df.string(from: Date(timeIntervalSince1970: TimeInterval(r.mtime)))
            out += "\(r.name)\t\(r.path)\t\(size)\t\(kind)\t\(date)\n"
        }
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }
}
