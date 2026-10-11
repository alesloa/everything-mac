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
    final class Preparation: Sendable {
        private let builders: [Builder]

        init(store: FileStore) {
            var builders: [Builder] = []
            if let base = store.cachedBaseValue(key: "unique-names-preparation", build: {
                Builder(store: store, records: 0..<store.baseCount, cachesBase: true)
            }) { builders.append(base) }
            if store.baseCount < store.count {
                builders.append(Builder(store: store, records: store.baseCount..<store.count, cachesBase: false))
            }
            self.builders = builders
        }

        func ready() -> UniqueNameIndex? {
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
        private let cancellation = SearchCancellation()

        init(store: FileStore, records: Range<Int>, cachesBase: Bool) {
            let cancellation = self.cancellation
            Self.queue.addOperation { [weak self] in
                guard !cancellation.isCancelled else { return }
                let build = { Layer(store: store, records: records, isCancelled: { cancellation.isCancelled }) }
                let layer = cachesBase ? store.cachedBaseValue(key: "unique-names", build: build) : build()
                guard let layer, !cancellation.isCancelled, let self else { return }
                self.lock.withLock { self.layer = layer }
            }
        }

        deinit { cancellation.cancel() }
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
            self.representatives = representatives
            self.masks = masks
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
        layers.reduce(0) { $0 + $1.recordNames.count * 4 + $1.representatives.count * 12 + $1.groupCount * 512 }
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
