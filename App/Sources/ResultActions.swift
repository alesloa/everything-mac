import AppKit
import IndexCore
import UniformTypeIdentifiers

@MainActor enum ResultActions {
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

    // Write tab-separated results, quoting legal filename delimiters. Sizes remain
    // raw bytes so the file stays script-friendly.
    static func exportResults(_ rows: [FileRecord]) {
        let panel = NSSavePanel()
        panel.title = "Export Results"
        panel.nameFieldStringValue = "EverythingMac-results.tsv"
        panel.allowedContentTypes = [.tabSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? exportedTSV(rows).write(to: url, atomically: true, encoding: .utf8)
    }

    static func exportedTSV(_ rows: [FileRecord]) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        // Source: the existing export column labels and each FileRecord below.
        var out = "Name\tPath\tSize\tKind\tDate Modified\n"
        for r in rows {
            let ext = (r.name as NSString).pathExtension.lowercased()
            let size = r.isDir ? "" : String(r.size)
            let kind = FileIcons.kind(ext: ext, isDir: r.isDir)
            let date = df.string(from: Date(timeIntervalSince1970: TimeInterval(r.mtime)))
            out += [r.name, r.path, size, kind, date].map(tsvField).joined(separator: "\t") + "\n"
        }
        return out
    }

    private static func tsvField(_ text: String) -> String {
        guard text.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\"" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
