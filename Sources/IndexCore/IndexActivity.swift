import Foundation

/// Sources: events come from scanner/reconciler/cache outcomes; labels below are
/// the app's definitions of those outcomes, and timestamps use the recording clock.
public enum IndexActivityKind: String, Sendable, CaseIterable {
    case added, removed, metadata, directoryReadFailed, replayIncomplete
    case scanStarted, scanCompleted, scanIncomplete, scanCancelled, scanFailed
    case cacheLoadStarted, cacheLoaded, cacheRejected, cacheLoadFailed
    case cacheSaveStarted, cacheSaved, cacheSaveFailed, cacheSaveSuperseded

    public var label: String {
        switch self {
        case .added: "Entry added"
        case .removed: "Entry removed"
        case .metadata: "Metadata observed"
        case .directoryReadFailed: "Read incomplete"
        case .replayIncomplete: "Live replay incomplete"
        case .scanStarted: "Scan started"
        case .scanCompleted: "Scan completed"
        case .scanIncomplete: "Scan incomplete"
        case .scanCancelled: "Scan cancelled"
        case .scanFailed: "Scan not accepted"
        case .cacheLoadStarted: "Cache load started"
        case .cacheLoaded: "Cache loaded"
        case .cacheRejected: "Cache not accepted"
        case .cacheLoadFailed: "Cache load failed"
        case .cacheSaveStarted: "Cache save started"
        case .cacheSaved: "Cache saved"
        case .cacheSaveFailed: "Cache save failed"
        case .cacheSaveSuperseded: "Cache save superseded"
        }
    }

    public var category: IndexActivityCategory {
        switch self {
        case .added, .removed, .metadata, .directoryReadFailed, .replayIncomplete: .files
        case .scanStarted, .scanCompleted, .scanIncomplete, .scanCancelled, .scanFailed: .scans
        default: .cache
        }
    }
}

public enum IndexActivityCategory: String, Sendable, CaseIterable {
    case files = "File observations", scans = "Scans", cache = "Cache"
}

public struct IndexActivityEvent: Identifiable, Sendable, Equatable {
    public let id: UInt64
    public let timestamp: Date
    public let kind: IndexActivityKind
    public let path: String
    public let detail: String?
    public let count: Int?
    public let metadata: IndexActivityMetadata?
}

/// Source: these are the indexed and fstatat-observed values from one reconcile listing.
public struct IndexActivityMetadata: Sendable, Equatable {
    public let size: UInt64
    public let modificationTime: Int64
    public let priorSize: UInt64
    public let priorModificationTime: Int64
}

public struct IndexActivityScan: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let path: String
    public let startedAt: Date
    public var observedCount: Int?
}

/// Sources: share names/configuration come from ExcludeRules; mount paths from the
/// cached mount table; counts and dates from accepted scans and progress callbacks.
public struct IndexActivityShare: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let mountPath: String?
    public let indexedPath: String?
    public let indexedCount: Int?
    public let observedCount: Int?
    public let scanning: Bool
    public let paused: Bool
    public let queued: Bool
    public let lastRefreshed: Date?

    public init(id: String, name: String, mountPath: String?, indexedPath: String?, indexedCount: Int?,
                observedCount: Int?, scanning: Bool, paused: Bool, queued: Bool, lastRefreshed: Date?) {
        self.id = id; self.name = name; self.mountPath = mountPath; self.indexedPath = indexedPath
        self.indexedCount = indexedCount; self.observedCount = observedCount; self.scanning = scanning
        self.paused = paused; self.queued = queued; self.lastRefreshed = lastRefreshed
    }
}

public struct IndexActivityCacheStatus: Sendable, Equatable {
    public var path: String?
    public var lastOperation: IndexActivityKind?
    public var lastOperationAt: Date?
    public var lastLoadedAt: Date?
    public var lastSavedAt: Date?
    public var byteCount: UInt64?
    public var modifiedAt: Date?
    public var detail: String?
    public init() {}
}

public struct IndexActivitySnapshot: Sendable {
    public let revision: UInt64
    public let events: [IndexActivityEvent]
    public let capacity: Int
    public let droppedEventCount: UInt64
    public let indexedCount: Int
    public let indexedRoots: [String]
    public let activeScans: [IndexActivityScan]
    public let shares: [IndexActivityShare]
    public let cache: IndexActivityCacheStatus

    /// This filters only already-recorded entries; it never queries the index or filesystem.
    public func events(category: IndexActivityCategory? = nil, root: String? = nil,
                       containing text: String = "") -> [IndexActivityEvent] {
        events.filter { event in
            if let category, event.kind.category != category { return false }
            if let root, !Self.contains(path: event.path, root: root) { return false }
            return text.isEmpty || event.path.localizedCaseInsensitiveContains(text)
                || event.kind.label.localizedCaseInsensitiveContains(text)
                || event.detail?.localizedCaseInsensitiveContains(text) == true
        }
    }

    private static func contains(path: String, root: String) -> Bool {
        if path.utf8.elementsEqual(root.utf8) { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.utf8.starts(with: prefix.utf8)
    }
}

/// A fixed-size memory journal, independent of the filesystem writer actor.
/// The lock guards bounded value copies only: no filesystem I/O, callbacks,
/// searching, or FileStore access can occur while it is held.
public final class IndexActivityJournal: @unchecked Sendable {
    public static let defaultCapacity = 1_000
    private let lock = NSLock()
    private let clock: @Sendable () -> Date
    private var slots: [IndexActivityEvent?]
    private var nextSlot = 0
    private var retained = 0
    private var sequence: UInt64 = 0
    private var revision: UInt64 = 0
    private var dropped: UInt64 = 0
    private var indexedCount = 0
    private var indexedRoots: [String] = []
    private var scans: [UUID: IndexActivityScan] = [:]
    private var shares: [IndexActivityShare] = []
    private var cache = IndexActivityCacheStatus()

    public init(capacity: Int = defaultCapacity, clock: @escaping @Sendable () -> Date = { Date() }) {
        slots = Array(repeating: nil, count: max(1, capacity))
        self.clock = clock
    }

    public func record(_ kind: IndexActivityKind, path: String, detail: String? = nil, count: Int? = nil) {
        let now = clock()
        lock.withLock { append(kind, at: now, path: path, detail: detail, count: count) }
    }

    private func append(_ kind: IndexActivityKind, at date: Date, path: String, detail: String?, count: Int?,
                        metadata: IndexActivityMetadata? = nil) {
        sequence &+= 1; revision &+= 1
        slots[nextSlot] = IndexActivityEvent(id: sequence, timestamp: date, kind: kind,
                                             path: path, detail: detail, count: count, metadata: metadata)
        nextSlot = (nextSlot + 1) % slots.count
        if retained == slots.count { dropped &+= 1 } else { retained += 1 }
    }

    /// Store primitive observations only; formatting belongs to the displayed rows.
    public func recordObservation(_ observation: ReconcileObservation) {
        let kind: IndexActivityKind
        var metadata: IndexActivityMetadata?
        switch observation.kind {
        case .added: kind = .added
        case .removed: kind = .removed
        case .incomplete: kind = .directoryReadFailed
        case .metadata:
            kind = .metadata
            guard let size = observation.size, let mtime = observation.modificationTime,
                  let priorSize = observation.priorSize, let priorMtime = observation.priorModificationTime else { return }
            metadata = IndexActivityMetadata(size: size, modificationTime: mtime,
                                              priorSize: priorSize, priorModificationTime: priorMtime)
        }
        let now = clock()
        lock.withLock {
            append(kind, at: now, path: observation.path, detail: observation.failure, count: nil, metadata: metadata)
        }
    }

    public func startScan(id: UUID, path: String) {
        let now = clock()
        lock.withLock {
            scans[id] = IndexActivityScan(id: id, path: path, startedAt: now, observedCount: nil)
            append(.scanStarted, at: now, path: path, detail: nil, count: nil)
        }
    }

    public func scanProgress(id: UUID, count: Int) {
        lock.withLock {
            guard var scan = scans[id] else { return }
            scan.observedCount = max(scan.observedCount ?? count, count)
            scans[id] = scan; revision &+= 1
        }
    }

    public func scanProgressCount(id: UUID) -> Int? { lock.withLock { scans[id]?.observedCount } }

    /// Retired workers cannot record completion/progress for an already-closed scan.
    public func finishScan(id: UUID, outcome: IndexActivityKind, detail: String? = nil, count: Int? = nil) {
        let now = clock()
        lock.withLock {
            guard let scan = scans.removeValue(forKey: id) else { return }
            append(outcome, at: now, path: scan.path, detail: detail, count: count)
        }
    }

    public func publishIndex(count: Int, roots: [String]) {
        lock.withLock { indexedCount = count; indexedRoots = roots; revision &+= 1 }
    }

    public func publishShares(_ values: [IndexActivityShare]) {
        lock.withLock { shares = values; revision &+= 1 }
    }

    /// Sources: file size/date are supplied by filesystem attributes after cache
    /// I/O; loaded/saved timestamps are when the actual operation returned.
    public func recordCache(_ kind: IndexActivityKind, path: String, detail: String? = nil,
                            byteCount: UInt64? = nil, modifiedAt: Date? = nil) {
        let now = clock()
        lock.withLock {
            cache.path = path; cache.lastOperation = kind; cache.lastOperationAt = now; cache.detail = detail
            if kind == .cacheLoaded { cache.lastLoadedAt = now }
            if kind == .cacheSaved { cache.lastSavedAt = now }
            if let byteCount { cache.byteCount = byteCount }
            if let modifiedAt { cache.modifiedAt = modifiedAt }
            append(kind, at: now, path: path, detail: detail, count: nil)
        }
    }

    public func snapshot() -> IndexActivitySnapshot {
        lock.withLock {
            let events = (0..<retained).compactMap { slots[(nextSlot - retained + $0 + slots.count) % slots.count] }
            return IndexActivitySnapshot(revision: revision, events: events, capacity: slots.count,
                droppedEventCount: dropped, indexedCount: indexedCount, indexedRoots: indexedRoots,
                activeScans: scans.values.sorted { $0.startedAt < $1.startedAt }, shares: shares, cache: cache)
        }
    }

    /// Clears only retained journal entries; current index and operation status survive.
    public func clear() {
        lock.withLock {
            slots = Array(repeating: nil, count: slots.count)
            nextSlot = 0; retained = 0; dropped = 0; revision &+= 1
        }
    }
}
