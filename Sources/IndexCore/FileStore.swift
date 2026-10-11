import Foundation

// Immutable mapped base plus an append-only, column-oriented live overlay. IDs
// are stable slots, including tombstones; compaction never renumbers records.
public struct FileStore: Sendable {
    public static let noParent: UInt32 = .max
    private var base: FileStoreBase?
    private var lineage = UUID()
    private var compactedRevision: UInt64 = 0
    private var nameBytes: [UInt8] = []
    private var nameOffset: [UInt32] = []
    private var nameLen: [UInt16] = []
    private var parents: [UInt32] = []
    private var sizes: [UInt64] = []
    private var mtimes: [Int64] = []
    private var flags: [UInt8] = []
    private var volIDs: [UInt32] = []
    private var nameMasks: [UInt64] = []
    // Sparse 64-slot tombstone words keep the cost proportional to live changes,
    // rather than copying every base record's live flag after each publication.
    private var deletedWords: [Int: UInt64] = [:]
    private var childrenByParent: [UInt32: [UInt32]] = [:]
    private var dirReconcileMtime: [UInt32: Int64] = [:]
    public private(set) var rootID: UInt32 = .max
    public private(set) var deletedCount = 0
    public private(set) var revision: UInt64 = 0
    /// Whether a fresh scan read every included subtree. Not persisted in cache;
    /// share refreshes use this to avoid replacing a complete tree with partial data.
    public private(set) var scanCompleted = true
    mutating func markScanIncomplete() { scanCompleted = false }
    public var hasDeletions: Bool { deletedCount > 0 }
    public var baseCount: Int { base?.count ?? 0 }
    public var overlayCount: Int { parents.count }
    public var count: Int { baseCount + overlayCount }
    public var baseIdentity: ObjectIdentifier? { base.map(ObjectIdentifier.init) }
    public var needsCompaction: Bool {
        count > 0 && (base == nil || overlayCount >= max(4_096, min(50_000, baseCount / 20)) || deletedWords.count >= max(256, min(4_096, baseCount / 512)))
    }
    public init() {}

    func cachedBaseValue<Value: Sendable>(key: String, build: () -> Value?) -> Value? {
        base?.cachedValue(key: key, build: build)
    }

    public func storageSnapshot() -> FileStore {
        var copy = self
        copy.childrenByParent = [:]
        copy.dirReconcileMtime = [:]
        return copy
    }

    func searchSnapshot() -> FileStore { storageSnapshot() }

    @discardableResult
    public mutating func append(name: String, parent: UInt32, size: UInt64,
                                mtime: Int64, isDir: Bool, volID: UInt32) -> UInt32 {
        let bytes = Array(name.utf8)
        precondition(count < Int(UInt32.max) && bytes.count <= Int(UInt16.max))
        precondition((base?.names.count ?? 0) + nameBytes.count <= Int(UInt32.max) - bytes.count)
        let id = UInt32(count)
        nameOffset.append(UInt32(nameBytes.count))
        nameLen.append(UInt16(bytes.count))
        nameBytes.append(contentsOf: bytes)
        nameMasks.append(FuzzyMatcher.mask(bytes))
        parents.append(parent); sizes.append(size); mtimes.append(mtime)
        flags.append(isDir ? 1 : 0); volIDs.append(volID)
        if parent == Self.noParent { rootID = id }
        else { childrenByParent[parent, default: []].append(id) }
        revision &+= 1
        return id
    }

    public func name(of id: UInt32) -> String {
        withNameArena { String(decoding: $0.bytes(in: nameRange(of: id)), as: UTF8.self) }
    }
    // Compatibility accessor; scan loops borrow withNameArena instead of copying.
    public func nameBytesSlice(of id: UInt32) -> ArraySlice<UInt8> {
        withNameArena { Array($0.bytes(in: nameRange(of: id)))[...] }
    }
    func nameMask(of id: UInt32) -> UInt64 {
        let i = Int(id)
        return i < baseCount ? base!.mask(i) : nameMasks[i - baseCount]
    }
    func nameRange(of id: UInt32) -> Range<Int> {
        let i = Int(id), count = baseCount
        if i < count {
            let start = Int(base!.value(1, i, as: UInt32.self))
            return start..<(start + Int(base!.value(2, i, as: UInt16.self)))
        }
        let start = (base?.names.count ?? 0) + Int(nameOffset[i - count])
        return start..<(start + Int(nameLen[i - count]))
    }
    func withNameArena<R>(_ body: (FileNameArena) -> R) -> R {
        nameBytes.withUnsafeBufferPointer {
            body(FileNameArena(base: base?.names ?? UnsafeBufferPointer(start: nil, count: 0), appended: $0))
        }
    }

    public func nameSortsBefore(_ a: UInt32, _ b: UInt32) -> Bool {
        withNameArena { arena in
            let left = arena.bytes(in: nameRange(of: a)), right = arena.bytes(in: nameRange(of: b))
            for i in 0..<min(left.count, right.count) {
                let ca = Self.lower(left[i]), cb = Self.lower(right[i])
                if ca != cb { return ca < cb }
            }
            return left.count < right.count
        }
    }
    private static func lower(_ c: UInt8) -> UInt8 { c >= 65 && c <= 90 ? c &+ 32 : c }
    private func extensionBytes(_ name: UnsafeBufferPointer<UInt8>) -> UnsafeBufferPointer<UInt8> {
        var i = name.count - 1
        while i > 0 {
            if name[i] == 46 { return UnsafeBufferPointer(start: name.baseAddress?.advanced(by: i + 1), count: name.count - i - 1) }
            i -= 1
        }
        return UnsafeBufferPointer(start: nil, count: 0)
    }
    public func kindSortsBefore(_ a: UInt32, _ b: UInt32) -> Bool {
        let ad = isDir(of: a), bd = isDir(of: b)
        if ad != bd { return ad }
        let cmp: Int = withNameArena { arena in
            let left = extensionBytes(arena.bytes(in: nameRange(of: a)))
            let right = extensionBytes(arena.bytes(in: nameRange(of: b)))
            for i in 0..<min(left.count, right.count) {
                let ca = Self.lower(left[i]), cb = Self.lower(right[i])
                if ca != cb { return ca < cb ? -1 : 1 }
            }
            return left.count == right.count ? 0 : (left.count < right.count ? -1 : 1)
        }
        return cmp == 0 ? nameSortsBefore(a, b) : cmp < 0
    }
    public func parent(of id: UInt32) -> UInt32 {
        let i = Int(id); return i < baseCount ? base!.value(3, i, as: UInt32.self) : parents[i - baseCount]
    }
    public func size(of id: UInt32) -> UInt64 {
        let i = Int(id); return i < baseCount ? base!.value(4, i, as: UInt64.self) : sizes[i - baseCount]
    }
    public func mtime(of id: UInt32) -> Int64 {
        let i = Int(id); return i < baseCount ? base!.value(5, i, as: Int64.self) : mtimes[i - baseCount]
    }
    public func isDir(of id: UInt32) -> Bool {
        let i = Int(id); let flag: UInt8 = i < baseCount ? base!.value(6, i, as: UInt8.self) : flags[i - baseCount]
        return flag & 1 == 1
    }
    public func volID(of id: UInt32) -> UInt32 {
        let i = Int(id); return i < baseCount ? base!.value(7, i, as: UInt32.self) : volIDs[i - baseCount]
    }
    public func isLive(_ id: UInt32) -> Bool {
        let i = Int(id)
        guard i < count else { return false }
        if let word = deletedWords[i >> 6], word & (UInt64(1) << (i & 63)) != 0 { return false }
        return i >= baseCount || base!.value(8, i, as: UInt8.self) == 1
    }
    public mutating func markDeleted(_ id: UInt32) {
        if isLive(id) {
                let i = Int(id)
            deletedWords[i >> 6, default: 0] |= UInt64(1) << (i & 63)
            deletedCount += 1; revision &+= 1
        }
    }
    public mutating func markSubtreeDeleted(_ id: UInt32) {
        var stack = [id]
        while let next = stack.popLast() {
            stack.append(contentsOf: childIDs(of: next))
            markDeleted(next)
        }
    }
    @discardableResult
    public mutating func markDeleted(volID: UInt32) -> Int {
        var removed = 0
        for i in 0..<count where isLive(UInt32(i)) && self.volID(of: UInt32(i)) == volID {
            markDeleted(UInt32(i)); removed += 1
        }
        return removed
    }
    public func liveCount(volID: UInt32) -> Int {
        (0..<count).reduce(into: 0) { n, i in
            if isLive(UInt32(i)) && self.volID(of: UInt32(i)) == volID { n += 1 }
        }
    }

    /// Graft a separately scanned tree under `parent`. The subtree's root becomes a
    /// new child of `parent` named by the last component of its root path; every
    /// other record is copied with remapped parent ids and tagged `volID`. Requires
    /// the subtree's records to be in parent-before-child order, which both scanners
    /// guarantee. Returns the id of the grafted root.
    @discardableResult
    public mutating func merge(_ sub: FileStore, asChildOf parent: UInt32, volID: UInt32) -> UInt32? {
        guard sub.rootID != Self.noParent else { return nil }
        let rootName = (sub.name(of: sub.rootID) as NSString).lastPathComponent
        var idMap = [UInt32](repeating: Self.noParent, count: sub.count)
        var newRoot: UInt32?
        for i in 0..<sub.count {
            let id = UInt32(i)
            guard sub.isLive(id) else { continue }
            if id == sub.rootID {
                let r = append(name: rootName, parent: parent, size: 0, mtime: 0, isDir: true, volID: volID)
                idMap[i] = r; newRoot = r
                continue
            }
            let p = idMap[Int(sub.parent(of: id))]
            guard p != Self.noParent else { continue }
            idMap[i] = append(name: sub.name(of: id), parent: p, size: sub.size(of: id),
                              mtime: sub.mtime(of: id), isDir: sub.isDir(of: id), volID: volID)
        }
        return newRoot
    }

    /// Live-reconcile fast path: the mtime (nanoseconds) a directory was last
    /// reconciled at. Repeat FSEvents whose dir mtime is unchanged take a cheap skip
    /// instead of re-reading the directory. nil until a dir's first reconcile this
    /// session, so the first event always reconciles in full — no same-second miss.
    public func reconcileMtime(of id: UInt32) -> Int64? { dirReconcileMtime[id] }
    public mutating func setReconcileMtime(_ id: UInt32, _ nsec: Int64) { dirReconcileMtime[id] = nsec }

    public func childIDs(of parent: UInt32) -> [UInt32] {
        guard let kids = childrenByParent[parent] else { return [] }
        return kids.filter { isLive($0) }
    }

    public func childID(named target: String, under parent: UInt32) -> UInt32? {
        childrenByParent[parent]?.first { isLive($0) && name(of: $0) == target }
    }

    // Resolve an absolute directory path to its id by walking the child index from
    // the root, one component at a time — O(depth), no full-path string building.
    // This is what FSEvents reconcile uses to locate a changed directory. The root
    // node's name is its full path ("/" for the app's whole-disk scan, or a temp
    // base path for a scoped Scanner), so we strip that prefix before walking.
    public func idForDirPath(_ path: String) -> UInt32? {
        guard rootID != Self.noParent, isLive(rootID), isDir(of: rootID) else { return nil }
        let rootName = name(of: rootID)
        if path == rootName { return rootID }
        guard rootName == "/" ? path.hasPrefix("/") : path.hasPrefix(rootName + "/") else { return nil }
        var rest = path.dropFirst(rootName.count)
        if rest.hasPrefix("/") { rest = rest.dropFirst() }   // unless rootName == "/"
        var cur = rootID
        for comp in rest.split(separator: "/", omittingEmptySubsequences: true) {
            guard let next = childID(named: String(comp), under: cur), isDir(of: next) else { return nil }
            cur = next
        }
        return cur
    }

    // EMS2 retains the EMS1 columns and appends precomputed search masks.
    // Stream columns directly from the mapping and small overlay; a cache save
    // never materializes a second full-size Data/array copy of the base.
    func writeBinary(_ emit: (UnsafeRawBufferPointer) throws -> Void) throws {
        func scalar<T>(_ value: T) throws {
            var value = value
            try withUnsafeBytes(of: &value, emit)
        }
        func column<T>(_ number: Int, _ appended: [T]) throws {
            try scalar(UInt64(count))
            if let base { try emit(UnsafeRawBufferPointer(start: base.bytes.address.advanced(by: base.columns[number].offset), count: base.columns[number].bytes.count)) }
            try appended.withUnsafeBytes(emit)
        }
        func generated<T>(_ values: (Int) -> T) throws {
            try scalar(UInt64(count))
            var start = 0
            while start < count {
                let end = min(count, start + 65_536)
                let chunk = (start..<end).map(values)
                try chunk.withUnsafeBytes(emit)
                start = end
            }
        }
        let baseBytes = base?.columns[0].count ?? 0
        guard baseBytes <= Int(UInt32.max) - nameBytes.count else { throw IndexCache.CacheError() }
        try Array("EMS2".utf8).withUnsafeBytes(emit)
        try scalar(UInt64(baseBytes + nameBytes.count))
        if let base { try emit(UnsafeRawBufferPointer(base.names)) }
        try nameBytes.withUnsafeBytes(emit)
        // Base offsets stay intact; overlay names follow the base arena.
        try scalar(UInt64(count))
        if let base { try emit(UnsafeRawBufferPointer(start: base.bytes.address.advanced(by: base.columns[1].offset), count: base.columns[1].bytes.count)) }
        var start = 0
        while start < nameOffset.count {
            let end = min(nameOffset.count, start + 65_536)
            let adjusted = nameOffset[start..<end].map { $0 + UInt32(baseBytes) }
            try adjusted.withUnsafeBytes(emit)
            start = end
        }
        try column(2, nameLen); try column(3, parents); try column(4, sizes)
        try column(5, mtimes); try column(6, flags); try column(7, volIDs)
        try generated { isLive(UInt32($0)) ? UInt8(1) : UInt8(0) }
        if let base, base.columns.count == 10 { try column(9, nameMasks) }
        else { try generated { nameMask(of: UInt32($0)) } }
    }
    func serializedBinary() -> Data {
        var result = Data()
        // writeBinary only throws for an arena beyond the format's UInt32 limit.
        try! writeBinary { result.append(contentsOf: $0) }
        return result
    }

    // All record fields are immutable after append. A delayed compaction can
    // therefore rebase the newly appended suffix and deletion words over its
    // completed base without losing updates or waiting for a quiet filesystem.
    /// `compacted` must originate from a storageSnapshot of this single writer.
    /// Independently mutated value forks are not valid compaction sources. The
    /// app enforces this contract by keeping every mutation on IndexActor.
    @discardableResult
    public mutating func adoptCompaction(_ compacted: FileStore, expectedRevision: UInt64) -> Bool {
        guard lineage == compacted.lineage, compacted.revision == expectedRevision,
              revision >= expectedRevision, expectedRevision >= compactedRevision, compacted.count <= count,
              baseCount <= compacted.count, compacted.base != nil,
              compacted.overlayCount == 0 else { return false }
        let cut = compacted.count - baseCount
        let nameCut = cut < nameOffset.count ? Int(nameOffset[cut]) : nameBytes.count
        nameBytes = Array(nameBytes[nameCut...])
        nameOffset = nameOffset[cut...].map { $0 - UInt32(nameCut) }
        nameLen = Array(nameLen[cut...]); parents = Array(parents[cut...])
        sizes = Array(sizes[cut...]); mtimes = Array(mtimes[cut...])
        flags = Array(flags[cut...]); volIDs = Array(volIDs[cut...])
        nameMasks = Array(nameMasks[cut...])
        // Discard deletion bits already persisted in the new base. Keep every
        // deletion made while compaction was running, including overlay records.
        var remaining: [Int: UInt64] = [:]
        for (wordID, word) in deletedWords {
            var bits = word, keep: UInt64 = 0
            while bits != 0 {
                let bit = bits.trailingZeroBitCount, id = wordID * 64 + bit
                if id >= compacted.count || compacted.base!.value(8, id, as: UInt8.self) == 1 {
                    keep |= UInt64(1) << bit
                }
                bits &= bits - 1
            }
            if keep != 0 { remaining[wordID] = keep }
        }
        deletedWords = remaining
        base = compacted.base
        compactedRevision = expectedRevision
        return true
    }

    /// Build a private mapping off the writer actor. The temporary pathname is
    /// unlinked immediately after mapping, so nobody can truncate its inode.
    public func compacted() throws -> FileStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("everything-base-\(UUID().uuidString).idx")
        defer { try? FileManager.default.removeItem(at: url) }
        try IndexCache.save(self, to: url, lastEventID: 0, rulesFingerprint: 0)
        var result = try IndexCache.load(from: url, buildWriterIndex: false).0
        result.revision = revision
        result.scanCompleted = scanCompleted
        result.lineage = lineage
        result.compactedRevision = revision
        return result
    }

    init?(storage: StoreBytes, offset: Int, buildWriterIndex: Bool = true) {
        guard let base = FileStoreBase(bytes: storage, offset: offset) else { return nil }
        self.base = base
        rootID = base.rootID; deletedCount = base.deletedCount
        if buildWriterIndex { rebuildChildIndex() }
    }
    init?(binary data: Data) { self.init(storage: StoreBytes(data: data), offset: 0) }

    private mutating func rebuildChildIndex() {
        childrenByParent.reserveCapacity(count / 4)
        for i in 0..<count {
            let p = parent(of: UInt32(i))
            if p != Self.noParent { childrenByParent[p, default: []].append(UInt32(i)) }
        }
    }
}

public extension FileStore {
    // Walk parents to root, then join. Root name "/" yields absolute paths.
    func path(of id: UInt32) -> String {
        var components: [String] = []
        var cur = id
        while cur != Self.noParent {
            components.append(name(of: cur))
            cur = parent(of: cur)
        }
        components.reverse()
        if components.first == "/" {
            let rest = components.dropFirst().joined(separator: "/")
            return rest.isEmpty ? "/" : "/" + rest
        }
        return components.joined(separator: "/")
    }
}
