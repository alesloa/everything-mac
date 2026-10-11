import AppKit
import SwiftUI
import QuickLookUI
import ImageIO
import UniformTypeIdentifiers
import IndexCore
import Darwin
import QuickLookThumbnailing
import Combine

@main struct QuickLookTests {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--verify-failure-exit") {
            check(false, "Intentional preview assertion failure")
        }
        let app = NSApplication.shared
        Task { @MainActor in
            do { try await run() }
            catch { print("FAIL: \(error)"); exit(EXIT_FAILURE) }
            exit(EXIT_SUCCESS)
        }
        // Quick Look panel ordering includes native AppKit animation callbacks.
        app.run()
    }

    @MainActor private static func run() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("quick-look-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let physicalPath = realpath(temporary.path, nil)!
        let directory = URL(fileURLWithPath: String(cString: physicalPath))
        free(physicalPath)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("fixture.png")
        try writeImage(to: imageURL)
        let textURL = directory.appendingPathComponent("fixture.txt")
        try Data("Actual native preview fixture\n".utf8).write(to: textURL)
        let unknownURL = directory.appendingPathComponent("fixture.unknown-format")
        try Data([0, 1, 2, 3]).write(to: unknownURL)
        let linkURL = directory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: imageURL)
        let image = record(imageURL, id: 1)
        let text = record(textURL, id: 2)
        let unknown = record(unknownURL, id: 3)
        let missing = record(directory.appendingPathComponent("missing.png"), id: 4)

        let resolved = await PreviewFileAccess.resolve(image)
        check(resolved != nil, "Existing local PNG must be eligible")
        check(await PreviewFileAccess.resolve(text) != nil)
        check(await PreviewFileAccess.resolve(unknown) != nil, "Native Quick Look decides format support")
        check(await PreviewFileAccess.resolve(missing) == nil)
        check(await PreviewFileAccess.resolve(record(directory, id: 5, isDir: true)) == nil)
        check(await PreviewFileAccess.resolve(record(linkURL, id: 6)) == nil)
        let ancestorLink = directory.appendingPathComponent("alternate")
        try FileManager.default.createSymbolicLink(at: ancestorLink, withDestinationURL: directory)
        check(await PreviewFileAccess.resolve(record(ancestorLink.appendingPathComponent("fixture.png"), id: 7)) == nil)
        let cancelledProbe = Task { await PreviewFileAccess.resolve(image) }
        cancelledProbe.cancel()
        check(await cancelledProbe.value == nil)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1234)], ofItemAtPath: imageURL.path)
        let changed = await PreviewFileAccess.resolve(image)
        check(changed?.fingerprint != resolved?.fingerprint, "Cache key must use current disk metadata")
        try FileManager.default.removeItem(at: textURL)
        check(await PreviewFileAccess.resolve(text) == nil, "Deleted indexed files must not preview")

        try keyboardTests(image)
        cacheTests(resolved!.fingerprint, changed!.fingerprint)
        selectionTests(image, unknown)
        let service = ThumbnailService(cache: ThumbnailCache(countLimit: 2, costLimit: 2 * 1024 * 1024), concurrencyLimit: 1)
        let thumbnail = await service.image(for: image)
        check(thumbnail != nil, "QuickLookThumbnailing must generate the real PNG fixture")
        check(service.cache.count == 1)
        let cached = await service.image(for: image)
        check(cached === thumbnail, "Identical live metadata should reuse the cached native image")
        check(await service.image(for: missing) == nil)
        _ = await service.image(for: unknown)
        let cancelledThumbnail = Task { await service.image(for: image, size: 511) }
        cancelledThumbnail.cancel()
        check(await cancelledThumbnail.value == nil)
        check(service.activeCount == 0 && service.queuedCount == 0)
        let requests = (0..<12).map { size in Task { await service.image(for: image, size: CGFloat(200 + size)) } }
        for request in requests { request.cancel() }
        for request in requests { check(await request.value == nil) }
        check(service.activeCount == 0 && service.queuedCount == 0)
        try await scheduledCancellationTests(image)
        try await viewportTests(directory, imageURL)
        try await windowLifetimeTests(image, unknown)

        let controller = QuickLookController.shared
        controller.show([image])
        controller.close()
        controller.show([missing])
        try await Task.sleep(for: .milliseconds(30))
        check(controller.numberOfPreviewItems(in: nil) == 0)
        check(controller.previewPanel(nil, previewItemAt: -1) == nil)
        check(controller.previewPanel(nil, previewItemAt: Int.max) == nil)
        controller.close()
        print("PASS: native PNG thumbnails, live-file cache keys, bounded cache, viewport-only generation, in-flight/queued cancellation, stale selection, keyboard focus, window ownership and missing/unsupported files")
    }

    private static func check(_ value: Bool, _ message: String = "Native preview assertion failed",
                              file: StaticString = #filePath, line: UInt = #line) {
        guard value else { fail(message, file: file, line: line) }
    }

    private static func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) -> Never {
        print("FAIL: \(message) (\(file):\(line))")
        exit(EXIT_FAILURE)
    }

    private static func record(_ url: URL, id: UInt32, isDir: Bool = false) -> FileRecord {
        FileRecord(id: id, name: url.lastPathComponent, path: url.path, parent: 0,
                   size: 0, mtime: 0, isDir: isDir, volID: 1)
    }

    private static func writeImage(to url: URL) throws {
        let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        check(CGImageDestinationFinalize(destination))
    }

    @MainActor private static func keyboardTests(_ image: FileRecord) throws {
        func event(_ keyCode: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        }
        let space = event(49, " ")
        check(ResultsKeyAction.action(for: space, isResultsFirstResponder: true) == .preview)
        check(ResultsKeyAction.action(for: space, isResultsFirstResponder: false) == nil)
        check(ResultsKeyAction.action(for: event(49, " ", .command), isResultsFirstResponder: true) == nil)
        check(ResultsKeyAction.action(for: event(36, "\r"), isResultsFirstResponder: true) == .open)
        check(ResultsKeyAction.action(for: event(8, "c", .command), isResultsFirstResponder: true) == .copy)
        check(ResultsKeyAction.action(for: event(9, "v", .command), isResultsFirstResponder: true) == .paste)
        check(ResultsKeyAction.action(for: event(6, "z", .command), isResultsFirstResponder: true) == .undo)
        check(ResultsKeyAction.action(for: event(6, "z", [.command, .shift]), isResultsFirstResponder: true) == nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentView!.bounds)
        let field = NSTextField(frame: NSRect(x: 0, y: 130, width: 300, height: 24))
        let table = ResultsKeyTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        let parent = ResultsTable(rows: [image], onSort: { _, _ in }, onSelect: { _ in }, onActivate: { _ in })
        let coordinator = ResultsTable.Coordinator(parent)
        coordinator.table = table
        table.dataSource = coordinator
        table.delegate = coordinator
        table.reloadData()
        root.addSubview(field)
        root.addSubview(table)
        window.contentView = root
        var previews = 0
        table.onResultKey = { action in if action == .preview { previews += 1; return true }; return false }
        check(window.makeFirstResponder(table))
        table.keyDown(with: space)
        check(previews == 1)
        var copied = false
        table.onResultKey = { action in copied = action == .copy; return copied }
        check(table.performKeyEquivalent(with: event(8, "c", .command)))
        check(copied)
        window.makeFirstResponder(field)
        field.currentEditor()?.insertText(" ")
        check(field.stringValue == " ", "The native field editor must receive spaces")
        check(previews == 1)
        window.close()
    }

    @MainActor private static func windowLifetimeTests(_ image: FileRecord, _ unknown: FileRecord) async throws {
        let a = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let b = NSWindow(contentRect: NSRect(x: 340, y: 0, width: 320, height: 180),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        a.isReleasedWhenClosed = false
        b.isReleasedWhenClosed = false
        a.orderFront(nil); b.orderFront(nil)
        // Supply the main/key-window lookup deterministically; this process need not steal desktop focus.
        let activeWindow = PreviewWindowLookup()
        activeWindow.window = a
        let controller = QuickLookController(activeWindow: { activeWindow.window })
        // These are the same ownership hooks called by SearchWindowRegistry on attach/detach.
        controller.registerOwnerWindow(a)
        controller.registerOwnerWindow(b)
        let closeA = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: a)
            .sink { _ in MainActor.assumeIsolated { controller.unregisterOwnerWindow(a) } }
        let closeB = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: b)
            .sink { _ in MainActor.assumeIsolated { controller.unregisterOwnerWindow(b) } }
        let originalA = a.nextResponder
        let originalB = b.nextResponder
        defer {
            controller.close()
            a.close(); b.close()
            closeA.cancel(); closeB.cancel()
        }

        controller.show([image])
        check(controller.hasPendingRequest)
        activeWindow.window = b
        try await waitUntil { !controller.hasPendingRequest }
        check(controller.numberOfPreviewItems(in: nil) == 0,
                     "A request must not publish when another search window becomes active")
        check(a.nextResponder === originalA && b.nextResponder === originalB)

        activeWindow.window = a
        controller.show([image])
        check(controller.hasPendingRequest)
        a.close()
        check(!controller.hasPendingRequest, "Closing the owner must cancel its pending request immediately")
        activeWindow.window = b
        controller.show([unknown])
        try await waitUntil { !controller.hasPendingRequest }
        check(controller.numberOfPreviewItems(in: nil) == 1)
        check((controller.previewPanel(nil, previewItemAt: 0) as? NSURL)?.path == unknown.path,
                     "A closed owner's stale request must not replace B's file")
        check(b.nextResponder === controller)

        // Reattach A while B owns the panel; its independent close must leave B's preview alone.
        controller.registerOwnerWindow(a)
        a.orderFront(nil)
        a.close()
        check(controller.numberOfPreviewItems(in: nil) == 1)
        check(b.nextResponder === controller)
        check(QLPreviewPanel.shared()?.isVisible == true)
        b.close()
        check(controller.numberOfPreviewItems(in: nil) == 0)
        check(b.nextResponder === originalB)
        try await waitUntil { QLPreviewPanel.shared()?.isVisible == false }
    }

    @MainActor private static func cacheTests(_ first: PreviewFile.Fingerprint, _ second: PreviewFile.Fingerprint) {
        let cache = ThumbnailCache(countLimit: 2, costLimit: 12)
        let image = NSImage(size: NSSize(width: 1, height: 1))
        let a = ThumbnailCache.Key(file: first, pixels: 1)
        let b = ThumbnailCache.Key(file: second, pixels: 2)
        let c = ThumbnailCache.Key(file: second, pixels: 3)
        cache.insert(image, for: a, cost: 4)
        cache.insert(image, for: b, cost: 4)
        check(cache.image(for: a) != nil)
        cache.insert(image, for: c, cost: 4)
        check(cache.count == 2 && cache.cost == 8)
        check(cache.image(for: b) == nil, "Least recently used entry must be evicted")
        cache.insert(image, for: a, cost: 12)
        check(cache.count == 1 && cache.cost == 12)
        cache.insert(image, for: c, cost: 13)
        check(cache.count == 1 && cache.cost == 12)
        cache.removeAll()
        check(cache.count == 0 && cache.cost == 0)
    }

    @MainActor private static func selectionTests(_ image: FileRecord, _ unknown: FileRecord) {
        var selected: [FileRecord] = []
        let grid = ThumbnailResultsView(rows: [image, unknown], selectedRecords: [image, unknown],
            onSelection: { selected = $0 }, onActivate: { _ in })
        let coordinator = ThumbnailResultsView.Coordinator(grid)
        let collection = ResultsKeyCollectionView()
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 156, height: 144)
        collection.collectionViewLayout = layout
        collection.register(NSCollectionViewItem.self, forItemWithIdentifier: .init("native-thumbnail"))
        collection.dataSource = coordinator
        collection.delegate = coordinator
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        coordinator.collection = collection
        coordinator.reload(grid)
        check(coordinator.selection() == [image, unknown])
        var next = grid
        next.rows = [unknown, image]
        coordinator.reload(next)
        check(coordinator.selection() == [unknown, image])
        next.rows = [record(URL(fileURLWithPath: image.path + ".replacement"), id: image.id)]
        coordinator.reload(next)
        check(coordinator.selection().isEmpty, "Reused index ID must not select another path")
        check(selected.isEmpty, "Programmatic reload must not report a user selection")
        coordinator.stop()

        let table = NSTableView()
        let parent = ResultsTable(rows: [image], onSort: { _, _ in }, onSelect: { _ in }, onActivate: { _ in }, selectedRecords: [image])
        let tableCoordinator = ResultsTable.Coordinator(parent)
        table.dataSource = tableCoordinator
        table.delegate = tableCoordinator
        tableCoordinator.table = table
        tableCoordinator.reload(parent)
        check(tableCoordinator.selectedRecords() == [image])
        var replacement = parent
        replacement.rows = next.rows
        tableCoordinator.reload(replacement)
        check(tableCoordinator.selectedRecords().isEmpty)
    }

    @MainActor private static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        fail("Asynchronous native request scheduling did not settle")
    }

    @MainActor private static func scheduledCancellationTests(_ image: FileRecord) async throws {
        let generator = HeldThumbnailGenerator()
        let service = ThumbnailService(concurrencyLimit: 1, generator: generator)
        let tasks = (0..<6).map { size in Task { await service.image(for: image, size: CGFloat(300 + size)) } }
        try await waitUntil { service.activeCount == 1 && service.queuedCount == 5 }
        check(generator.requests.count == 1, "Bounded scheduling must not start queued native requests")
        let first = generator.requests[0]
        let lateCompletion = generator.completions[ObjectIdentifier(first)]!
        for task in tasks { task.cancel() }
        for task in tasks { check(await task.value == nil) }
        check(service.activeCount == 0 && service.queuedCount == 0)
        check(!generator.cancelled.isEmpty, "In-flight Quick Look requests must be cancelled")
        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: image.path) as CFURL, nil)!
        lateCompletion(CGImageSourceCreateImageAtIndex(source, 0, nil)!)
        await Task.yield()
        check(service.cache.count == 0, "A late cancelled callback must not enter the cache")
    }

    @MainActor private static func viewportTests(_ directory: URL, _ source: URL) async throws {
        var rows: [FileRecord] = []
        for index in 0..<80 {
            let url = directory.appendingPathComponent("visible-\(index).png")
            try FileManager.default.copyItem(at: source, to: url)
            rows.append(record(url, id: UInt32(index + 100)))
        }
        let generator = HeldThumbnailGenerator()
        let service = ThumbnailService(concurrencyLimit: 2, generator: generator)
        let parent = ThumbnailResultsView(rows: rows, onSelection: { _ in }, onActivate: { _ in })
        let coordinator = ThumbnailResultsView.Coordinator(parent, thumbnailService: service)
        let collection = ResultsKeyCollectionView(frame: NSRect(x: 0, y: 0, width: 360, height: 260))
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 156, height: 144)
        collection.collectionViewLayout = layout
        collection.register(NSCollectionViewItem.self, forItemWithIdentifier: .init("native-thumbnail"))
        collection.dataSource = coordinator
        collection.delegate = coordinator
        collection.autoresizingMask = [.width]
        coordinator.collection = collection
        let scroll = NSScrollView(frame: collection.frame)
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.observe(scroll.contentView)
        coordinator.reload(parent)
        collection.layoutSubtreeIfNeeded()
        coordinator.refreshVisible()
        check(coordinator.loadingCount == 0, "Hidden results must not request thumbnails")
        window.orderFront(nil)
        collection.layoutSubtreeIfNeeded()
        coordinator.refreshVisible()
        try await waitUntil { service.activeCount == 2 }
        let initial = collection.indexPathsForVisibleItems().filter {
            collection.item(at: $0)?.view.frame.intersects(collection.visibleRect) == true
        }
        check(coordinator.loadingCount == initial.count)
        check(initial.count > 0 && initial.count < rows.count)
        check(service.activeCount + service.queuedCount <= initial.count,
                     "Offscreen records must not be submitted to the generator")
        let staleCompletion = generator.completions[ObjectIdentifier(generator.requests[0])]!
        var replacement = parent
        replacement.rows = []
        coordinator.reload(replacement)
        try await waitUntil { service.activeCount == 0 && service.queuedCount == 0 }
        let sourceImage = CGImageSourceCreateWithURL(source as CFURL, nil)!
        staleCompletion(CGImageSourceCreateImageAtIndex(sourceImage, 0, nil)!)
        await Task.yield()
        check(coordinator.loadingCount == 0 && coordinator.selection().isEmpty)
        check(service.cache.count == 0)
        coordinator.stop()
        window.close()
    }
}

@MainActor private final class HeldThumbnailGenerator: ThumbnailGenerating {
    var requests: [QLThumbnailGenerator.Request] = []
    var completions: [ObjectIdentifier: @Sendable (CGImage?) -> Void] = [:]
    var cancelled: Set<ObjectIdentifier> = []

    func generate(_ request: QLThumbnailGenerator.Request, completion: @escaping @Sendable (CGImage?) -> Void) {
        requests.append(request)
        completions[ObjectIdentifier(request)] = completion
    }

    func cancel(_ request: QLThumbnailGenerator.Request) { cancelled.insert(ObjectIdentifier(request)) }
}

@MainActor private final class PreviewWindowLookup {
    weak var window: NSWindow?
}
