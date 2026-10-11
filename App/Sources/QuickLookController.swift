import AppKit
import QuickLookUI
import IndexCore

// Quick Look's legacy Objective-C protocols omit actor annotations. AppKit
// invokes these UI callbacks on its main thread; the bridge enforces that rule.
@MainActor final class QuickLookController: NSResponder, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    static let shared = QuickLookController()
    private var files: [PreviewFile] = []
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private weak var hostWindow: NSWindow?

    func show(_ records: [FileRecord], allowsNetwork: Bool = false) {
        task?.cancel()
        requestID = UUID()
        let request = requestID
        files = []
        if QLPreviewPanel.sharedPreviewPanelExists(),
           let panel = QLPreviewPanel.shared(), panel.currentController as AnyObject? === self {
            panel.reloadData()
        }
        guard !records.isEmpty else { close(); return }
        task = Task {
            var resolved: [PreviewFile] = []
            for record in records {
                guard !Task.isCancelled else { return }
                if let file = await PreviewFileAccess.resolve(record, allowsNetwork: allowsNetwork) { resolved.append(file) }
            }
            guard !Task.isCancelled, request == requestID else { return }
            files = resolved
            guard !files.isEmpty else { close(); return }
            installResponder()
            guard let panel = QLPreviewPanel.shared() else { return }
            panel.updateController()
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
            panel.currentPreviewItemIndex = 0
        }
    }

    func toggle(_ records: [FileRecord], allowsNetwork: Bool = false) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared()?.isVisible == true { close() }
        else { show(records, allowsNetwork: allowsNetwork) }
    }

    func updateSelection(_ records: [FileRecord], allowsNetwork: Bool = false) {
        guard QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared()?.isVisible == true else { return }
        show(records, allowsNetwork: allowsNetwork)
    }

    func close() {
        task?.cancel()
        task = nil
        requestID = UUID()
        files = []
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() {
            panel.orderOut(nil)
        }
        if hostWindow?.nextResponder === self { hostWindow?.nextResponder = nextResponder }
        hostWindow = nil
        nextResponder = nil
    }

    private func installResponder() {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow, window !== QLPreviewPanel.shared() else { return }
        if hostWindow === window, window.nextResponder === self { return }
        if hostWindow?.nextResponder === self { hostWindow?.nextResponder = nextResponder }
        hostWindow = window
        nextResponder = window.nextResponder
        window.nextResponder = self
    }

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { !files.isEmpty }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { files.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard files.indices.contains(index) else { return nil }
        // Source: the actual verified file URL; Quick Look owns rendered content.
        return files[index].url as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, let panel,
              ResultsKeyAction.action(for: event, isResultsFirstResponder: true) == .preview,
              !(panel.firstResponder is NSTextView), !(panel.firstResponder is NSTextField) else { return false }
        close()
        return true
    }
}
