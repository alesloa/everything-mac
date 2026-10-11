import AppKit
import SwiftUI
import IndexCore

struct BatchRenameRule: Sendable {
    enum Mode: String, CaseIterable, Sendable { case replace, addText, number }
    var mode: Mode = .replace
    var find = ""
    var replacement = ""
    var prefix = ""
    var suffix = ""
    var start = 1
    var preserveExtension = true

    func transfers(for records: [FileRecord]) throws -> [FileTransfer] {
        try records.enumerated().map { index, record in
            let url = URL(fileURLWithPath: record.path)
            let ext = preserveExtension && !record.isDir ? (record.name as NSString).pathExtension : ""
            let stem = ext.isEmpty ? record.name : (record.name as NSString).deletingPathExtension
            let renamed: String
            switch mode {
            case .replace:
                renamed = find.isEmpty ? stem : stem.replacingOccurrences(of: find, with: replacement)
            case .addText: renamed = prefix + stem + suffix
            case .number:
                let (number, overflow) = start.addingReportingOverflow(index)
                guard !overflow else {
                    throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: record.path])
                }
                renamed = prefix + String(number) + suffix
            }
            let name = renamed + (ext.isEmpty ? "" : "." + ext)
            try FileOperationEngine.validateName(name, path: record.path)
            return FileTransfer(source: url, destination: url.deletingLastPathComponent().appendingPathComponent(name))
        }.filter { !$0.source.path.utf8.elementsEqual($0.destination.path.utf8) }
    }
}

@MainActor enum BatchRenameDialog {
    static func show(_ records: [FileRecord]) -> [FileTransfer]? {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 650, height: 480),
                            styleMask: [.titled], backing: .buffered, defer: false)
        // Source: the owner's batch-rename request and the selected FileRecord names below.
        panel.title = "Rename Files"
        var result: [FileTransfer]?
        panel.contentView = NSHostingView(rootView: RenameView(records: records) { transfers in
            result = transfers
            NSApplication.shared.stopModal()
            panel.orderOut(nil)
        })
        panel.center()
        NSApplication.shared.runModal(for: panel)
        return result
    }

    private struct RenameView: View {
        let records: [FileRecord]
        let completion: ([FileTransfer]?) -> Void
        @State private var rule = BatchRenameRule()
        @State private var validationError: String?
        @State private var validating = false

        var body: some View {
            let preview = previewNames
            // Source: controls implement the owner's rename request; previews use FileRecord names and the user's rule.
            VStack(alignment: .leading, spacing: 12) {
                Picker("Rename", selection: $rule.mode) {
                    Text("Replace Text").tag(BatchRenameRule.Mode.replace)
                    Text("Add Text").tag(BatchRenameRule.Mode.addText)
                    Text("Number Files").tag(BatchRenameRule.Mode.number)
                }.pickerStyle(.segmented)
                if rule.mode == .replace {
                    TextField("Find", text: $rule.find)
                    TextField("Replace With", text: $rule.replacement)
                } else {
                    TextField("Prefix", text: $rule.prefix)
                    TextField("Suffix", text: $rule.suffix)
                    if rule.mode == .number { TextField("Start At", value: $rule.start, format: .number) }
                }
                Toggle("Preserve file extensions", isOn: $rule.preserveExtension)
                ScrollView {
                    Grid(alignment: .leading) {
                        GridRow { Text("Current Name").bold(); Text("New Name").bold() }
                        ForEach(Array(records.enumerated()), id: \.offset) { index, record in
                            GridRow {
                                Text(record.name).lineLimit(1)
                                Text(preview[index]).lineLimit(1)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: .infinity)
                if let validationError { Text(validationError).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    Spacer()
                    Button("Cancel") { completion(nil) }.keyboardShortcut(.cancelAction)
                    Button("Rename") { validate() }.keyboardShortcut(.defaultAction).disabled(validating)
                }
            }.padding(20)
        }

        private var previewNames: [String] {
            // Compute in the full selection so numbered previews retain their original position.
            do {
                let transfers = try rule.transfers(for: records)
                let byPath = Dictionary(transfers.map {
                    (Array($0.source.path.utf8), $0.destination.lastPathComponent)
                }, uniquingKeysWith: { first, _ in first })
                return records.map { byPath[Array($0.path.utf8)] ?? $0.name }
            } catch { return Array(repeating: (error as NSError).localizedDescription, count: records.count) }
        }

        private func validate() {
            do {
                let transfers = try rule.transfers(for: records)
                validating = true
                Task {
                    do {
                        try await FileOperationEngine().validate(transfers, allowCycles: true)
                        completion(transfers)
                    } catch {
                        validationError = (error as NSError).localizedDescription
                        validating = false
                    }
                }
            } catch { validationError = (error as NSError).localizedDescription }
        }
    }
}
