import AppKit
import IndexCore
import UniformTypeIdentifiers

@MainActor enum ResultActions {
    static let state = FileActionState()

    static func open(_ rec: FileRecord) { open([rec]) }
    static func open(_ records: [FileRecord]) {
        for url in urls(records) {
            NSWorkspace.shared.open(url, configuration: .init()) { _, error in
                guard let error else { return }
                let message = error.localizedDescription
                Task { @MainActor in state.showError(message, title: "Open") }
            }
        }
    }
    static func open(_ rec: FileRecord, with appURL: URL) { open([rec], with: appURL) }
    static func open(_ records: [FileRecord], with appURL: URL) {
        NSWorkspace.shared.open(urls(records), withApplicationAt: appURL, configuration: .init()) { _, error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor in state.showError(message, title: "Open With") }
        }
    }
    static func reveal(_ rec: FileRecord) { reveal([rec]) }
    static func reveal(_ records: [FileRecord]) { NSWorkspace.shared.activateFileViewerSelecting(urls(records)) }
    static func copyPath(_ rec: FileRecord) { copyPath([rec]) }
    static func copyPath(_ records: [FileRecord]) { copyText(records.map(\.path).joined(separator: "\n")) }
    static func copyName(_ rec: FileRecord) { copyName([rec]) }
    static func copyName(_ records: [FileRecord]) { copyText(records.map(\.name).joined(separator: "\n")) }
    static func trash(_ rec: FileRecord) { trash([rec]) }
    static func trash(_ records: [FileRecord]) {
        guard !records.isEmpty else { return }
        state.perform(.trash(urls(records)), title: "Move to Trash")
    }

    static func copyFiles(_ records: [FileRecord], to pasteboard: NSPasteboard = .general) {
        guard !records.isEmpty else { return }
        pasteboard.clearContents()
        _ = pasteboard.writeObjects(urls(records).map { $0 as NSURL })
    }

    static var canPasteFiles: Bool { canPasteFiles(from: .general) }
    static func canPasteFiles(from pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    static func pasteFiles(into directory: FileRecord? = nil) {
        guard !state.isBusy,
              let values = NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                           options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !values.isEmpty else { return }
        let destination: URL?
        if let directory, directory.isDir { destination = URL(fileURLWithPath: directory.path) }
        else { destination = chooseDirectory(title: "Paste Files Into") }
        guard let destination else { return }
        state.perform(.copy(values.map { FileTransfer(source: $0, destination: destination.appendingPathComponent($0.lastPathComponent)) }),
                      title: "Paste Files")
    }

    static func copyTo(_ records: [FileRecord]) { transfer(records, move: false) }
    static func moveTo(_ records: [FileRecord]) { transfer(records, move: true) }
    static func undoLastOperation() { state.undo() }

    static func rename(_ records: [FileRecord]) {
        let records = uniqueRecords(records)
        guard !records.isEmpty, !state.isBusy else { return }
        if records.count > 1 {
            if let transfers = BatchRenameDialog.show(records), !transfers.isEmpty {
                state.perform(.rename(transfers), title: "Rename Files")
            }
            return
        }
        let record = records[0]
        let alert = NSAlert()
        // Source: the requested Rename action and the selected FileRecord's current name.
        alert.messageText = "Rename"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: record.name)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileOperationEngine.validateName(field.stringValue, path: record.path)
            let source = URL(fileURLWithPath: record.path)
            let destination = source.deletingLastPathComponent().appendingPathComponent(field.stringValue)
            guard !source.path.utf8.elementsEqual(destination.path.utf8) else { return }
            state.perform(.rename([FileTransfer(source: source, destination: destination)]), title: "Rename")
        } catch { state.showError((error as NSError).localizedDescription, title: "Rename") }
    }

    static func getInfo(_ records: [FileRecord]) {
        guard !records.isEmpty else { return }
        let paths = uniqueRecords(records).map(\.path)
        Task.detached {
            do {
                // NSAppleScript is main-thread-only. Run the system interpreter separately instead.
                let process = Process()
                let input = Pipe(), errors = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = FinderInfoRequest.arguments(for: paths)
                process.standardInput = input
                process.standardOutput = FileHandle.nullDevice
                process.standardError = errors
                try process.run()
                try input.fileHandleForWriting.write(contentsOf: Data(FinderInfoRequest.script.utf8))
                try input.fileHandleForWriting.close()
                let data = try errors.fileHandleForReading.readToEnd() ?? Data()
                process.waitUntilExit()
                if process.terminationStatus != 0, !data.isEmpty {
                    await state.showError(String(decoding: data, as: UTF8.self), title: "Get Info")
                }
            } catch { await state.showError((error as NSError).localizedDescription, title: "Get Info") }
        }
    }

    private static func transfer(_ records: [FileRecord], move: Bool) {
        guard !records.isEmpty, !state.isBusy,
              let directory = chooseDirectory(title: move ? "Move Files To" : "Copy Files To") else { return }
        let transfers = urls(records).map { FileTransfer(source: $0, destination: directory.appendingPathComponent($0.lastPathComponent)) }
        state.perform(move ? .move(transfers) : .copy(transfers), title: move ? "Move Files" : "Copy Files")
    }

    private static func chooseDirectory(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func urls(_ records: [FileRecord]) -> [URL] { uniqueRecords(records).map { URL(fileURLWithPath: $0.path) } }
    private static func uniqueRecords(_ records: [FileRecord]) -> [FileRecord] {
        var paths = Set<[UInt8]>()
        return records.filter { paths.insert(Array($0.path.utf8)).inserted }
    }
    private static func copyText(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    // Write tab-separated results, quoting legal filename delimiters. Sizes remain
    // raw bytes so the file stays script-friendly.
    static func exportResults(_ rows: [FileRecord]) {
        let panel = NSSavePanel()
        panel.title = "Export Results"
        panel.nameFieldStringValue = "EverythingMac-results.tsv"
        panel.allowedContentTypes = [.tabSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try exportedTSV(rows).write(to: url, atomically: true, encoding: .utf8) }
        catch { state.showError((error as NSError).localizedDescription, title: "Export Results") }
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
