import AppKit
import QuickLookThumbnailing
import IndexCore

@MainActor protocol ThumbnailGenerating: AnyObject {
    func generate(_ request: QLThumbnailGenerator.Request, completion: @escaping @Sendable (CGImage?) -> Void)
    func cancel(_ request: QLThumbnailGenerator.Request)
}

@MainActor private final class NativeThumbnailGenerator: ThumbnailGenerating {
    func generate(_ request: QLThumbnailGenerator.Request, completion: @escaping @Sendable (CGImage?) -> Void) {
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            completion(representation?.cgImage)
        }
    }

    func cancel(_ request: QLThumbnailGenerator.Request) { QLThumbnailGenerator.shared.cancel(request) }
}

@MainActor final class ThumbnailCache {
    struct Key: Hashable {
        let file: PreviewFile.Fingerprint
        let pixels: Int
    }
    private struct Entry {
        let image: NSImage
        let cost: Int
        var accessed: UInt64
    }
    let countLimit: Int
    let costLimit: Int
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var cost = 0
    var count: Int { entries.count }

    init(countLimit: Int = 128, costLimit: Int = 64 * 1024 * 1024) {
        self.countLimit = max(0, countLimit)
        self.costLimit = max(0, costLimit)
    }

    func image(for key: Key) -> NSImage? {
        guard var entry = entries[key] else { return nil }
        clock &+= 1
        entry.accessed = clock
        entries[key] = entry
        return entry.image
    }

    func insert(_ image: NSImage, for key: Key, cost imageCost: Int) {
        if let old = entries.removeValue(forKey: key) { cost -= old.cost }
        guard countLimit > 0, imageCost >= 0, imageCost <= costLimit else { return }
        while entries.count >= countLimit || cost > costLimit - imageCost {
            guard let oldest = entries.min(by: { $0.value.accessed < $1.value.accessed })?.key,
                  let old = entries.removeValue(forKey: oldest) else { break }
            cost -= old.cost
        }
        clock &+= 1
        entries[key] = Entry(image: image, cost: imageCost, accessed: clock)
        cost += imageCost
    }

    func removeAll() { entries.removeAll(); cost = 0 }
}

@MainActor final class ThumbnailService {
    static let shared = ThumbnailService()
    let cache: ThumbnailCache
    let concurrencyLimit: Int
    private let generator: any ThumbnailGenerating
    private struct Pending {
        let id: UUID
        let request: QLThumbnailGenerator.Request
        let continuation: CheckedContinuation<CGImage?, Never>
    }
    private var active: [UUID: Pending] = [:]
    private var queued: [Pending] = []
    var activeCount: Int { active.count }
    var queuedCount: Int { queued.count }

    init(cache: ThumbnailCache = ThumbnailCache(), concurrencyLimit: Int = 4,
         generator: (any ThumbnailGenerating)? = nil) {
        self.cache = cache
        self.concurrencyLimit = max(1, concurrencyLimit)
        self.generator = generator ?? NativeThumbnailGenerator()
    }

    func image(for record: FileRecord, size: CGFloat = 128, scale: CGFloat = 2,
               allowsNetwork: Bool = false) async -> NSImage? {
        guard !Task.isCancelled, size.isFinite, scale.isFinite, size > 0, scale > 0,
              let file = await PreviewFileAccess.resolve(record, allowsNetwork: allowsNetwork),
              !Task.isCancelled else { return nil }
        // Bound both native request dimensions and image memory independently of
        // result count or caller-provided display scale.
        let pixels = Int(min(1024, max(1, (size * scale).rounded(.up))))
        let key = ThumbnailCache.Key(file: file.fingerprint, pixels: pixels)
        if let cached = cache.image(for: key) { return cached }
        let request = QLThumbnailGenerator.Request(fileAt: file.url,
            size: CGSize(width: pixels, height: pixels), scale: 1, representationTypes: .all)
        let id = UUID()
        let cgImage = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                let pending = Pending(id: id, request: request, continuation: continuation)
                if active.count < concurrencyLimit { start(pending) }
                else { queued.append(pending) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel(id) } }
        guard !Task.isCancelled, let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: CGSize(width: size, height: size))
        let imageCost = cgImage.bytesPerRow.multipliedReportingOverflow(by: cgImage.height)
        if !imageCost.overflow { cache.insert(image, for: key, cost: imageCost.partialValue) }
        return image
    }

    private func start(_ pending: Pending) {
        active[pending.id] = pending
        let id = pending.id
        generator.generate(pending.request) { [weak self] image in
            Task { @MainActor [weak self] in self?.finish(id, image: image) }
        }
    }

    private func finish(_ id: UUID, image: CGImage?) {
        guard let pending = active.removeValue(forKey: id) else { return }
        pending.continuation.resume(returning: image)
        drain()
    }

    private func cancel(_ id: UUID) {
        if let pending = active.removeValue(forKey: id) {
            generator.cancel(pending.request)
            pending.continuation.resume(returning: nil)
        } else if let index = queued.firstIndex(where: { $0.id == id }) {
            queued.remove(at: index).continuation.resume(returning: nil)
        }
        drain()
    }

    private func drain() {
        while active.count < concurrencyLimit, !queued.isEmpty { start(queued.removeFirst()) }
    }
}
