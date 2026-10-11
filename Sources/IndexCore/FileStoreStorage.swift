import Foundation
import Darwin

// One immutable owner for a native mapping. The app only replaces cache files
// atomically; readers keep the old inode mapped until their snapshots disappear.
// APFS mappings use an unlinked clone; on other filesystems in-place truncation
// of a mapped inode is unsupported (it can cause SIGBUS).
final class StoreBytes: @unchecked Sendable {
    let address: UnsafeRawPointer
    let count: Int
    private let mapped: Bool
    let isIsolatedMapping: Bool

    init(file url: URL) throws {
        // APFS clonefile is an inexpensive CoW inode snapshot. When available,
        // mapping the unlinked clone also isolates readers from external in-place
        // writes/truncation; unsupported filesystems retain atomic-replace safety.
        let clone = url.deletingLastPathComponent().appendingPathComponent(".mapped-\(UUID().uuidString).tmp")
        let isolated = clonefile(url.path, clone.path, 0) == 0
        defer { if isolated { unlink(clone.path) } }
        // A corrupted/replaced cache path may be a FIFO. Never wait for a writer
        // before fstat can reject it; O_NONBLOCK does not alter regular files.
        let fd = open((isolated ? clone : url).path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw IndexCache.CacheError() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= Int.max else {
            throw IndexCache.CacheError()
        }
        count = Int(info.st_size)
        let pointer = mmap(nil, count, PROT_READ, MAP_PRIVATE, fd, 0)
        guard pointer != MAP_FAILED, let pointer else { throw IndexCache.CacheError() }
        address = UnsafeRawPointer(pointer)
        mapped = true
        isIsolatedMapping = isolated
    }

    init(data: Data) {
        count = data.count
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: max(1, count), alignment: 8)
        data.copyBytes(to: UnsafeMutableRawBufferPointer(start: pointer, count: count))
        address = UnsafeRawPointer(pointer)
        mapped = false
        isIsolatedMapping = false
    }

    deinit {
        if mapped { munmap(UnsafeMutableRawPointer(mutating: address), count) }
        else { UnsafeMutableRawPointer(mutating: address).deallocate() }
    }

    func value<T>(at offset: Int, as type: T.Type) -> T {
        address.loadUnaligned(fromByteOffset: offset, as: type)
    }
    func buffer(in range: Range<Int>) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: address.advanced(by: range.lowerBound).assumingMemoryBound(to: UInt8.self), count: range.count)
    }
}

struct StoreColumn: Sendable {
    let offset: Int
    let count: Int
    let stride: Int
    var bytes: Range<Int> { offset..<(offset + count * stride) }
}

// Metadata remains in the mapped file: loadUnaligned is required because EMS1
// array offsets were never padded. EMS2 adds masks without invalidating EMS1.
final class FileStoreBase: @unchecked Sendable {
    let bytes: StoreBytes
    let columns: [StoreColumn]
    let count: Int
    let rootID: UInt32
    let deletedCount: Int
    private let legacyMasks: [UInt64]
    private let derivedLock = NSLock()
    private var derivedValues: [String: any Sendable] = [:]

    init?(bytes: StoreBytes, offset: Int) {
        guard offset >= 0, bytes.count - offset >= 4 else { return nil }
        let magic = Array(bytes.buffer(in: offset..<(offset + 4)))
        let hasMasks = magic == Array("EMS2".utf8)
        guard hasMasks || magic == Array("EMS1".utf8) else { return nil }
        var cursor = offset + 4
        var columns: [StoreColumn] = []
        for stride in hasMasks ? [1, 4, 2, 4, 8, 8, 1, 4, 1, 8] : [1, 4, 2, 4, 8, 8, 1, 4, 1] {
            guard bytes.count - cursor >= 8 else { return nil }
            let rawCount = bytes.value(at: cursor, as: UInt64.self)
            cursor += 8
            guard rawCount <= UInt64((bytes.count - cursor) / stride) else { return nil }
            let column = StoreColumn(offset: cursor, count: Int(rawCount), stride: stride)
            columns.append(column)
            cursor = column.bytes.upperBound
        }
        guard cursor == bytes.count else { return nil }
        let n = columns[3].count
        guard n <= Int(UInt32.max), columns.dropFirst().allSatisfy({ $0.count == n }) else { return nil }
        var root = FileStore.noParent, deleted = 0
        var masks: [UInt64] = []
        if !hasMasks { masks.reserveCapacity(n) }
        for i in 0..<n {
            let start = Int(bytes.value(at: columns[1].offset + i * 4, as: UInt32.self))
            let length = Int(bytes.value(at: columns[2].offset + i * 2, as: UInt16.self))
            let parent = bytes.value(at: columns[3].offset + i * 4, as: UInt32.self)
            let live = bytes.value(at: columns[8].offset + i, as: UInt8.self)
            let flags = bytes.value(at: columns[6].offset + i, as: UInt8.self)
            guard start <= columns[0].count, length <= columns[0].count - start,
                  parent == FileStore.noParent || parent < UInt32(i), live <= 1, flags <= 1 else { return nil }
            if parent == FileStore.noParent { root = UInt32(i) }
            if live == 0 { deleted += 1 }
            if !hasMasks {
                masks.append(FuzzyMatcher.mask(bytes.buffer(in: (columns[0].offset + start)..<(columns[0].offset + start + length))))
            }
        }
        self.bytes = bytes
        self.columns = columns
        count = n
        rootID = root
        deletedCount = deleted
        legacyMasks = masks
    }

    func value<T>(_ column: Int, _ id: Int, as type: T.Type) -> T {
        bytes.value(at: columns[column].offset + id * columns[column].stride, as: type)
    }
    func mask(_ id: Int) -> UInt64 {
        columns.count == 10 ? value(9, id, as: UInt64.self) : legacyMasks[id]
    }
    var names: UnsafeBufferPointer<UInt8> { bytes.buffer(in: columns[0].bytes) }
    func cachedValue<Value: Sendable>(key: String, build: () -> Value?) -> Value? {
        if let cached = derivedLock.withLock({ derivedValues[key] as? Value }) { return cached }
        // Building millions of names must never hold the shared cache lock.
        // Cancellation returns nil; only a complete value can be installed.
        guard let value = build() else { return nil }
        return derivedLock.withLock {
            if let cached = derivedValues[key] as? Value { return cached }
            derivedValues[key] = value
            return value
        }
    }
}

// A name never spans the immutable and appended arenas. Borrowing both buffers
// once per worker avoids copying a mapped name or retaining its owner per record.
struct FileNameArena {
    let base: UnsafeBufferPointer<UInt8>
    let appended: UnsafeBufferPointer<UInt8>
    func bytes(in range: Range<Int>) -> UnsafeBufferPointer<UInt8> {
        let source = range.lowerBound < base.count ? base : appended
        let start = range.lowerBound < base.count ? range.lowerBound : range.lowerBound - base.count
        return UnsafeBufferPointer(start: source.baseAddress?.advanced(by: start), count: range.count)
    }
}
