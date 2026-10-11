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
    private weak var ownerWindow: NSWindow?
    private let registeredWindows = NSHashTable<NSWindow>.weakObjects()
    private let activeWindow: @MainActor () -> NSWindow?
    var hasPendingRequest: Bool { task != nil }

    init(activeWindow: @escaping @MainActor () -> NSWindow? = { NSApp.mainWindow ?? NSApp.keyWindow }) {
        self.activeWindow = activeWindow
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    // Source: SearchWindowRegistry mirrors each search window's attach/detach lifecycle.
    func registerOwnerWindow(_ window: NSWindow) { registeredWindows.add(window) }

    func unregisterOwnerWindow(_ window: NSWindow) {
        registeredWindows.remove(window)
        if ownerWindow === window { close() }
    }

    private var activeOwnerWindow: NSWindow? {
        guard let window = activeWindow(), registeredWindows.contains(window) else { return nil }
        return window
    }

    func show(_ records: [FileRecord], allowsNetwork: Bool = false) {
        guard let window = activeOwnerWindow else { return }
        if ownerWindow !== window { close() }
        ownerWindow = window
        task?.cancel()
        requestID = UUID()
        let request = requestID
        files = []
        if QLPreviewPanel.sharedPreviewPanelExists(),
           let panel = QLPreviewPanel.shared(), panel.currentController as AnyObject? === self {
            panel.reloadData()
        }
        guard !records.isEmpty else { close(); return }
        task = Task { [weak window] in
            var resolved: [PreviewFile] = []
            for record in records {
                guard !Task.isCancelled else { return }
                if let file = await PreviewFileAccess.resolve(record, allowsNetwork: allowsNetwork) { resolved.append(file) }
            }
            guard !Task.isCancelled, request == requestID else { return }
            guard let window, ownerWindow === window, activeOwnerWindow === window,
                  window.isVisible, !window.isMiniaturized else { close(); return }
            task = nil
            files = resolved
            guard !files.isEmpty else { close(); return }
            installResponder(in: window)
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
        ownerWindow = nil
        nextResponder = nil
    }

    private func installResponder(in window: NSWindow) {
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
