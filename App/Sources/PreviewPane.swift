import SwiftUI
import QuickLookUI
import IndexCore

struct PreviewPane: View {
    var records: [FileRecord]
    var allowsNetwork = false
    @State private var ready: PreviewFile?

    init(records: [FileRecord], allowsNetwork: Bool = false) {
        self.records = records
        self.allowsNetwork = allowsNetwork
    }

    init(record: FileRecord?, allowsNetwork: Bool = false) {
        self.init(records: record.map { [$0] } ?? [], allowsNetwork: allowsNetwork)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let record = records.first {
                // Source: the selected indexed FileRecord, matching table text.
                Text(record.name).font(.headline).lineLimit(2)
                Text(record.path).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(3)
                if let ready, SelectionIdentity(ready.record) == SelectionIdentity(record) {
                    NativePreview(file: ready)
                } else {
                    Spacer()
                }
            }
        }
        .padding(12)
        .task(id: input) {
            ready = nil
            guard let record = records.first else { return }
            let file = await PreviewFileAccess.resolve(record, allowsNetwork: allowsNetwork)
            guard !Task.isCancelled else { return }
            ready = file
        }
    }

    private var input: Input {
        Input(record: records.first, allowsNetwork: allowsNetwork)
    }

    private struct Input: Equatable {
        let record: FileRecord?
        let allowsNetwork: Bool
    }
}

private struct NativePreview: NSViewRepresentable {
    var file: PreviewFile

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.shouldCloseWithWindow = false
        view.autostarts = false
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        // Source: the verified local/opted-in file URL; native Quick Look renders
        // supported contents and supplies its own unsupported-format UI.
        if (view.previewItem as? NSURL) != file.url as NSURL { view.previewItem = file.url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.previewItem = nil
        view.close()
    }
}
