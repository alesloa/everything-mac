import Foundation

// Immutable filename dictionary. Keys are exact UTF-8 bytes, so original case,
// Unicode spelling and case-sensitive scores are never merged accidentally.
// Representatives borrow the snapshot's name arena; no filename Strings survive
// construction. The transposed masks test 64 names with one UInt64 operation.
final class UniqueNameIndex: Sendable {
    struct Requirement: Sendable {
        let mask: UInt64
        let allowsMissingCharacter: Bool
        let firstCharacter: UInt64
    }

    // At most two dictionaries are built at once. A snapshot never waits for a
    // build: queries use the per-record matcher until all its layers are ready.
    // Base builders belong to the immutable base, so frequent overlay publication
    // cannot continually cancel/restart a multi-million-name base dictionary.
    final class Preparation: @unchecked Sendable {
        private let builders: [Builder]
        private let lock = NSLock()
        private var released = false

        init(store: FileStore) {
            var builders: [Builder] = []
            if let base = store.cachedBaseValue(key: "unique-names-preparation", build: { Builder() }) {
                base.acquire(store: store, records: 0..<store.baseCount, cachesBase: true)
                builders.append(base)
            }
            if store.baseCount < store.count {
                let overlay = Builder()
                overlay.acquire(store: store, records: store.baseCount..<store.count, cachesBase: false)
                builders.append(overlay)
            }
            self.builders = builders
        }

        deinit { cancel() }

        func cancel() {
            let shouldRelease = lock.withLock {
                if released { return false }
                released = true
                return true
            }
            if shouldRelease { for builder in builders { builder.release() } }
        }

        func ready() -> UniqueNameIndex? {
            guard !lock.withLock({ released }) else { return nil }
            var layers: [Layer] = []
            for builder in builders {
                guard let layer = builder.ready() else { return nil }
                layers.append(layer)
            }
            return UniqueNameIndex(layers: layers)
        }
    }

    private final class Builder: @unchecked Sendable {
        private static let queue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "EverythingMac.unique-names"
            queue.qualityOfService = .utility
            queue.maxConcurrentOperationCount = 2
            return queue
        }()
        private let lock = NSLock()
        private var layer: Layer?
        private var leases = 0
        private var job: Job?

        // The queue captures a weak Job, not a FileStore. Cancelling a queued job
        // clears its input immediately, releasing obsolete mappings even while
        // both workers are busy. A running job checks its cancellation token.
        private final class Job: @unchecked Sendable {
            struct Inputs: Sendable {
                let store: FileStore
                let records: Range<Int>
                let cachesBase: Bool
            }
            let operation = BlockOperation()
            let cancellation = SearchCancellation()
            private let lock = NSLock()
            private var inputs: Inputs?
            init(store: FileStore, records: Range<Int>, cachesBase: Bool) {
                inputs = Inputs(store: store, records: records, cachesBase: cachesBase)
            }
            func takeInputs() -> Inputs? {
                lock.withLock { let previous = inputs; inputs = nil; return previous }
            }
            func cancel() {
                cancellation.cancel()
                let previous = takeInputs()
                operation.cancel()
                withExtendedLifetime(previous) {}
            }
        }

        func acquire(store: FileStore, records: Range<Int>, cachesBase: Bool) {
            let started: Job? = lock.withLock {
                leases += 1
                guard layer == nil, job == nil else { return nil }
                let started = Job(store: store, records: records, cachesBase: cachesBase)
                job = started
                return started
            }
            guard let started else { return }
            started.operation.addExecutionBlock { [weak self, weak started] in
                guard let started, let inputs = started.takeInputs() else { return }
                let cancellation = started.cancellation
                guard !cancellation.isCancelled else { self?.finished(nil, job: started); return }
                let build = {
                    let layer = Layer(store: inputs.store, records: inputs.records,
                                      isCancelled: { cancellation.isCancelled })
                    return cancellation.isCancelled ? nil : layer
                }
                let layer = inputs.cachesBase
                    ? inputs.store.cachedBaseValue(key: "unique-names", build: build) : build()
                self?.finished(layer, job: started)
            }
            Self.queue.addOperation(started.operation)
        }

        func release() {
            let previous: Job? = lock.withLock {
                leases -= 1
                guard leases == 0 else { return nil }
                let previous = job
                job = nil
                return previous
            }
            previous?.cancel()
        }

        private func finished(_ layer: Layer?, job: Job) {
            let previous: Job? = lock.withLock {
                // A cancelled builder may already have a new lease/job. An older
                // completion must not overwrite that job or publish its result.
                guard self.job === job else { return nil }
                if !job.cancellation.isCancelled, let layer { self.layer = layer }
                let previous = self.job
                self.job = nil
                return previous
            }
            withExtendedLifetime(previous) {}
        }

        func ready() -> Layer? { lock.withLock { layer } }
    }

    final class Layer: Sendable {
        let recordRange: Range<Int>
        let representatives: [UInt32]
        let masks: [UInt64]
        let recordNames: [UInt32]
        private let bitmaps: [UInt64]

        init?(store: FileStore, records: Range<Int>, isCancelled: @Sendable () -> Bool = { false }) {
            recordRange = records
            var representatives: [UInt32] = []
            var masks: [UInt64] = []
            var recordNames: [UInt32] = []
            recordNames.reserveCapacity(records.count)
            // Open addressing avoids allocating a String or Data for every file.
            // The temporary hashes are discarded when the dictionary is frozen.
            var hashes: [UInt64] = []
            var slots = [UInt32](repeating: 0, count: 1024)
            var cancelled = false
            store.withNameArena { arena in
                for i in records {
                    if i & 1023 == 0 && isCancelled() { cancelled = true; return }
                    let id = UInt32(i)
                    let bytes = arena.bytes(in: store.nameRange(of: id))
                    var hash: UInt64 = 14695981039346656037
                    var mask: UInt64 = 0
                    for byte in bytes {
                        hash = (hash ^ UInt64(byte)) &* 1099511628211
                        mask |= FuzzyMatcher.bit(byte)
                    }
                    var slot = Int(truncatingIfNeeded: hash) & (slots.count - 1)
                    var found: UInt32?
                    while slots[slot] != 0 {
                        let nameID = slots[slot] - 1
                        if hashes[Int(nameID)] == hash {
                            let previous = arena.bytes(in: store.nameRange(of: representatives[Int(nameID)]))
                            if bytes.elementsEqual(previous) { found = nameID; break }
                        }
                        slot = (slot + 1) & (slots.count - 1)
                    }
                    if let found { recordNames.append(found); continue }
                    let nameID = UInt32(representatives.count)
                    representatives.append(id)
                    hashes.append(hash)
                    masks.append(mask)
                    recordNames.append(nameID)
                    slots[slot] = nameID + 1
                    if representatives.count * 10 > slots.count * 7 {
                        slots = [UInt32](repeating: 0, count: slots.count * 2)
                        for (name, fingerprint) in hashes.enumerated() {
                            if name & 1023 == 0 && isCancelled() { cancelled = true; return }
                            var target = Int(truncatingIfNeeded: fingerprint) & (slots.count - 1)
                            while slots[target] != 0 { target = (target + 1) & (slots.count - 1) }
                            slots[target] = UInt32(name) + 1
                        }
                    }
                }
            }
            guard !cancelled else { return nil }
            hashes = []
            slots = []
            // Freeze to exact-size buffers instead of retaining geometric growth
            // capacity in the immutable dictionary for the rest of the session.
            self.representatives = representatives.withUnsafeBufferPointer { Array($0) }
            self.masks = masks.withUnsafeBufferPointer { Array($0) }
            self.recordNames = recordNames
            var bitmaps = [UInt64](repeating: 0, count: ((masks.count + 63) / 64) * 64)
            for (name, mask) in masks.enumerated() {
                if name & 1023 == 0 && isCancelled() { return nil }
                let group = (name / 64) * 64
                let position = UInt64(1) << (name & 63)
                var characters = mask
                while characters != 0 {
                    bitmaps[group + characters.trailingZeroBitCount] |= position
                    characters &= characters - 1
                }
            }
            self.bitmaps = bitmaps
        }

        var groupCount: Int { (representatives.count + 63) / 64 }
        var derivedByteCount: Int {
            recordNames.capacity * 4 + representatives.capacity * 4 + masks.capacity * 8 + bitmaps.capacity * 8
        }

        // Colliding character classes can admit extra names, but never discard a
        // real match. One-edit matching permits one absent class while retaining
        // the first character; requiring every query character would lose typos.
        func candidates(in group: Int, requirements: [Requirement]) -> UInt64 {
            let remaining = representatives.count - group * 64
            let valid = remaining >= 64 ? UInt64.max : (UInt64(1) << remaining) - 1
            var candidates = valid
            for requirement in requirements {
                var clean = valid
                var oneMissing: UInt64 = 0
                var characters = requirement.mask
                while characters != 0 {
                    let present = bitmaps[group * 64 + characters.trailingZeroBitCount]
                    if requirement.allowsMissingCharacter {
                        oneMissing = (oneMissing & present) | (clean & ~present)
                    }
                    clean &= present
                    characters &= characters - 1
                }
                if requirement.allowsMissingCharacter {
                    let first = bitmaps[group * 64 + requirement.firstCharacter.trailingZeroBitCount]
                    clean |= oneMissing & first
                }
                candidates &= clean
                if candidates == 0 { break }
            }
            return candidates
        }
    }

    let layers: [Layer]
    var uniqueNameCount: Int { layers.reduce(0) { $0 + $1.representatives.count } }
    var derivedByteCount: Int {
        layers.reduce(0) { $0 + $1.derivedByteCount }
    }

    init(store: FileStore) { layers = [Layer(store: store, records: 0..<store.count)!] }
    private init(layers: [Layer]) { self.layers = layers }

    // FileStore's immutable base owns its derived dictionary. New snapshots reuse
    // it and build only their small append overlay; tombstones are checked when
    // expanding scored names, so deletions require no dictionary rebuild.
    static func forSnapshot(_ store: FileStore) -> UniqueNameIndex {
        forSnapshot(store, isCancelled: { false })!
    }

    static func forSnapshot(_ store: FileStore,
                            isCancelled: @Sendable () -> Bool) -> UniqueNameIndex? {
        guard !isCancelled() else { return nil }
        var layers: [Layer] = []
        if let base = store.cachedBaseValue(key: "unique-names", build: {
            Layer(store: store, records: 0..<store.baseCount, isCancelled: isCancelled)
        }) { layers.append(base) }
        guard !isCancelled() else { return nil }
        if store.baseCount < store.count {
            guard let overlay = Layer(store: store, records: store.baseCount..<store.count,
                                      isCancelled: isCancelled) else { return nil }
            layers.append(overlay)
        }
        guard !isCancelled() else { return nil }
        return UniqueNameIndex(layers: layers)
    }
}
