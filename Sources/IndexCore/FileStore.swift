import Foundation

// Flat in-memory index. Names live in one contiguous UTF-8 arena; metadata in
// parallel arrays indexed by record id. Full path is reconstructed by walking
// `parents` to the root.
public struct FileStore: Sendable {
    public static let noParent: UInt32 = .max

    private var nameBytes: [UInt8] = []
    private var nameOffset: [UInt32] = []
    private var nameLen: [UInt16] = []
    private var parents: [UInt32] = []
    private var sizes: [UInt64] = []
    private var mtimes: [Int64] = []
    private var flags: [UInt8] = []     // bit0 = isDir
    private var volIDs: [UInt32] = []
    private var live: [Bool] = []

    // parent id → its child ids. Without this, child/path lookups are O(n) scans
    // that rebuild every record's path string — FSEvents reconcile then pegs a
    // core for tens of seconds and starves search. Derived (not serialized);
    // rebuilt on binary load and maintained on append.
    private var childrenByParent: [UInt32: [UInt32]] = [:]
    // dir id → last-reconciled mtime (ns). Derived, not serialized; see reconcileMtime.
    private var dirReconcileMtime: [UInt32: Int64] = [:]
    public private(set) var rootID: UInt32 = .max

    // Count of tombstoned (deleted) records. Lets the empty-query path return the
    // whole id range directly when nothing's been deleted, instead of filtering
    // millions of live records just to drop a handful of dead ones.
    public private(set) var deletedCount: Int = 0
    public var hasDeletions: Bool { deletedCount > 0 }

    public init() {}

    public var count: Int { parents.count }

    /// Appends a new record to the store and returns its id.
    /// `name` must be a single path component (≤ NAME_MAX = 255 bytes).
    /// `nameLen` is stored as `UInt16`; names longer than 65535 bytes will trap.
    @discardableResult
    public mutating func append(name: String, parent: UInt32, size: UInt64,
                                mtime: Int64, isDir: Bool, volID: UInt32) -> UInt32 {
        let bytes = Array(name.utf8)
        let id = UInt32(parents.count)
        nameOffset.append(UInt32(nameBytes.count))
        nameLen.append(UInt16(bytes.count))
        nameBytes.append(contentsOf: bytes)
        parents.append(parent)
        sizes.append(size)
        mtimes.append(mtime)
        flags.append(isDir ? 1 : 0)
        volIDs.append(volID)
        live.append(true)
        if parent == Self.noParent { rootID = id }
        else { childrenByParent[parent, default: []].append(id) }
        return id
    }

    public func name(of id: UInt32) -> String {
        let i = Int(id)
        let start = Int(nameOffset[i])
        let end = start + Int(nameLen[i])
        return String(decoding: nameBytes[start..<end], as: UTF8.self)
    }

    public func nameBytesSlice(of id: UInt32) -> ArraySlice<UInt8> {
        let i = Int(id)
        let start = Int(nameOffset[i])
        return nameBytes[start..<(start + Int(nameLen[i]))]
    }

    /// ASCII-case-insensitive lexicographic compare of two records' names by their
    /// raw UTF-8 bytes. Returns true if `a` sorts before `b`. This replaces
    /// `String.localizedStandardCompare`, which dominated typing latency — folding
    /// 'A'–'Z' inline over the byte arena is ~20× faster and allocation-free, so
    /// even sorting a multi-million-id match set stays responsive.
    public func nameSortsBefore(_ a: UInt32, _ b: UInt32) -> Bool {
        let ai = Int(a), bi = Int(b)
        let aStart = Int(nameOffset[ai]), aLen = Int(nameLen[ai])
        let bStart = Int(nameOffset[bi]), bLen = Int(nameLen[bi])
        let n = min(aLen, bLen)
        return nameBytes.withUnsafeBufferPointer { buf in
            var i = 0
            while i < n {
                var ca = buf[aStart + i]
                var cb = buf[bStart + i]
                if ca >= 65 && ca <= 90 { ca &+= 32 }   // 'A'–'Z' → lowercase
                if cb >= 65 && cb <= 90 { cb &+= 32 }
                if ca != cb { return ca < cb }
                i += 1
            }
            return aLen < bLen
        }
    }

    // Byte range of a record's file extension within `nameBytes` (the chars after
    // the last interior '.'). Leading dot (hidden file) doesn't count, so a name
    // like ".gitignore" has no extension. Returns len 0 when there's none.
    private func extRange(of id: UInt32) -> (start: Int, len: Int) {
        let i = Int(id)
        let start = Int(nameOffset[i]); let len = Int(nameLen[i])
        var dot = -1
        nameBytes.withUnsafeBufferPointer { buf in
            var j = len - 1
            while j > 0 {                       // j > 0: a leading dot is not a separator
                if buf[start + j] == 46 { dot = j; break }   // '.'
                j -= 1
            }
        }
        if dot <= 0 { return (start + len, 0) }
        return (start + dot + 1, len - dot - 1)
    }

    // Order by file "kind": directories first (grouped), then files grouped by
    // extension (ASCII case-insensitive), with name as the tiebreak so equal
    // kinds stay name-ordered. Same allocation-free byte path as nameSortsBefore.
    public func kindSortsBefore(_ a: UInt32, _ b: UInt32) -> Bool {
        let ad = isDir(of: a), bd = isDir(of: b)
        if ad != bd { return ad }              // folders before files
        let (aStart, aLen) = extRange(of: a)
        let (bStart, bLen) = extRange(of: b)
        let n = min(aLen, bLen)
        let cmp: Int = nameBytes.withUnsafeBufferPointer { buf in
            var i = 0
            while i < n {
                var ca = buf[aStart + i], cb = buf[bStart + i]
                if ca >= 65 && ca <= 90 { ca &+= 32 }
                if cb >= 65 && cb <= 90 { cb &+= 32 }
                if ca != cb { return ca < cb ? -1 : 1 }
                i += 1
            }
            if aLen != bLen { return aLen < bLen ? -1 : 1 }
            return 0
        }
        if cmp != 0 { return cmp < 0 }
        return nameSortsBefore(a, b)
    }

    public func parent(of id: UInt32) -> UInt32 { parents[Int(id)] }
    public func size(of id: UInt32) -> UInt64 { sizes[Int(id)] }
    public func mtime(of id: UInt32) -> Int64 { mtimes[Int(id)] }
    public func isDir(of id: UInt32) -> Bool { flags[Int(id)] & 1 == 1 }
    public func volID(of id: UInt32) -> UInt32 { volIDs[Int(id)] }

    public func isLive(_ id: UInt32) -> Bool { live[Int(id)] }
    public mutating func markDeleted(_ id: UInt32) {
        if live[Int(id)] { live[Int(id)] = false; deletedCount += 1 }
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
        guard rootID != Self.noParent else { return nil }
        let rootName = name(of: rootID)
        if path == rootName { return rootID }
        guard path.hasPrefix(rootName) else { return nil }
        var rest = path.dropFirst(rootName.count)
        if rest.hasPrefix("/") { rest = rest.dropFirst() }   // unless rootName == "/"
        var cur = rootID
        for comp in rest.split(separator: "/", omittingEmptySubsequences: true) {
            guard let next = childID(named: String(comp), under: cur) else { return nil }
            cur = next
        }
        return cur
    }

    // MARK: - Binary serialization
    //
    // The parallel arrays are dumped as raw little-endian bytes with a length
    // prefix per array. Loading is a handful of memcpys, so a multi-million-record
    // index restores in ~1s — versus tens of seconds to JSON-parse the same data.
    // Layout: ["EMS1" magic] then, for each array: [UInt64 count][raw element bytes].
    private static let magic: [UInt8] = Array("EMS1".utf8)

    private static func appendArray<T>(_ arr: [T], to data: inout Data) {
        var n = UInt64(arr.count)
        withUnsafeBytes(of: &n) { data.append(contentsOf: $0) }
        arr.withUnsafeBytes { data.append(contentsOf: $0) }
    }

    // Reads `count` then `count` elements of T (via memcpy, alignment-safe).
    private static func readArray<T>(_ : T.Type, from data: Data, _ cursor: inout Int) -> [T]? {
        guard cursor + 8 <= data.count else { return nil }
        let n = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: UInt64.self) }
        cursor += 8
        let bytes = Int(n) * MemoryLayout<T>.stride
        guard cursor + bytes <= data.count else { return nil }
        let arr = [T](unsafeUninitializedCapacity: Int(n)) { buf, initialized in
            if bytes > 0 {
                data.copyBytes(to: UnsafeMutableRawBufferPointer(buf), from: cursor..<(cursor + bytes))
            }
            initialized = Int(n)
        }
        cursor += bytes
        return arr
    }

    func serializedBinary() -> Data {
        var data = Data()
        data.append(contentsOf: Self.magic)
        Self.appendArray(nameBytes, to: &data)
        Self.appendArray(nameOffset, to: &data)
        Self.appendArray(nameLen, to: &data)
        Self.appendArray(parents, to: &data)
        Self.appendArray(sizes, to: &data)
        Self.appendArray(mtimes, to: &data)
        Self.appendArray(flags, to: &data)
        Self.appendArray(volIDs, to: &data)
        Self.appendArray(live, to: &data)
        return data
    }

    init?(binary data: Data) {
        var cursor = 0
        guard data.count >= Self.magic.count,
              Array(data[0..<Self.magic.count]) == Self.magic else { return nil }
        cursor = Self.magic.count
        guard let nb = Self.readArray(UInt8.self, from: data, &cursor),
              let no = Self.readArray(UInt32.self, from: data, &cursor),
              let nl = Self.readArray(UInt16.self, from: data, &cursor),
              let pa = Self.readArray(UInt32.self, from: data, &cursor),
              let sz = Self.readArray(UInt64.self, from: data, &cursor),
              let mt = Self.readArray(Int64.self, from: data, &cursor),
              let fl = Self.readArray(UInt8.self, from: data, &cursor),
              let vo = Self.readArray(UInt32.self, from: data, &cursor),
              let lv = Self.readArray(Bool.self, from: data, &cursor) else { return nil }
        nameBytes = nb; nameOffset = no; nameLen = nl; parents = pa
        sizes = sz; mtimes = mt; flags = fl; volIDs = vo; live = lv
        rebuildChildIndex()
    }

    // Rebuild the derived parent→children index (and rootID) from `parents`.
    // O(n) single pass — called after a binary load, since the index isn't stored.
    private mutating func rebuildChildIndex() {
        childrenByParent.removeAll(keepingCapacity: false)
        childrenByParent.reserveCapacity(parents.count / 4)
        rootID = Self.noParent
        deletedCount = 0
        for i in 0..<parents.count {
            let p = parents[i]
            if p == Self.noParent { rootID = UInt32(i) }
            else { childrenByParent[p, default: []].append(UInt32(i)) }
            if !live[i] { deletedCount += 1 }
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
