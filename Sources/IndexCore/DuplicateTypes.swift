import Foundation

public enum DuplicateScope: Sendable {
    case paths([String])
    case query(snapshot: FileStore, query: Query, folderPath: String? = nil)
    case folder(String)
}

public enum DuplicateMethod: Sendable {
    case nameAndSize
    case contents
}

public struct DuplicateOptions: Sendable {
    public var allowsNetwork: Bool
    public var allowsDownloadedCloudFiles: Bool
    public var workers: Int
    public var chunkBytes: Int

    public init(allowsNetwork: Bool = false, allowsDownloadedCloudFiles: Bool = false,
                workers: Int = 4, chunkBytes: Int = 1_048_576) {
        self.allowsNetwork = allowsNetwork
        self.allowsDownloadedCloudFiles = allowsDownloadedCloudFiles
        self.workers = min(8, max(1, workers))
        self.chunkBytes = min(8_388_608, max(1, chunkBytes))
    }
}

public struct DuplicateFile: Sendable, Hashable, Identifiable {
    public var id: [UInt8] { Array(path.utf8) }
    public let path: String
    public let name: String
    public let size: UInt64
    public let modificationDate: Date
    let fingerprint: DuplicateFingerprint

    init(path: String, fingerprint: DuplicateFingerprint) {
        self.path = path
        name = (path as NSString).lastPathComponent
        size = UInt64(fingerprint.size)
        modificationDate = Date(timeIntervalSince1970: Double(fingerprint.modifiedSeconds)
            + Double(fingerprint.modifiedNanoseconds) / 1_000_000_000)
        self.fingerprint = fingerprint
    }
}

public struct DuplicateGroup: Sendable, Identifiable {
    public var id: [UInt8] { files.first?.id ?? [] }
    public let files: [DuplicateFile]
    public let sha256: String?
    public var size: UInt64 { files.first?.size ?? 0 }
}

public enum DuplicateSkipReason: Sendable {
    case unavailable, symbolicLink, specialFile, network, cloud, changed
}

public struct DuplicateSkippedFile: Sendable {
    public let path: String
    public let reason: DuplicateSkipReason
}

public struct DuplicateReport: Sendable {
    public let method: DuplicateMethod
    public let groups: [DuplicateGroup]
    public let inspectedFiles: Int
    public let hashedFiles: Int
    public let skipped: [DuplicateSkippedFile]
    public let cancelled: Bool
}

public struct DuplicateProgress: Sendable {
    public enum Phase: Sendable { case inspecting, hashing, validating, finished }
    public let phase: Phase
    public let inspectedFiles: Int
    public let hashedFiles: Int
    public let hashCandidates: Int
    public let bytesRead: UInt64
}

struct DuplicateFingerprint: Sendable, Hashable {
    let device: Int32
    let inode: UInt64
    let generation: UInt32
    let mode: UInt16
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
}

typealias DuplicateCancellation = BackgroundFileJobCancellation

// The progress values are counts of inspected files and bytes actually read.
final class DuplicateProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var inspected = 0
    private var hashed = 0
    private var bytes: UInt64 = 0
    private var candidates = 0
    private var lastEmission = Date.distantPast
    private let callback: @Sendable (DuplicateProgress) -> Void

    init(callback: @escaping @Sendable (DuplicateProgress) -> Void) { self.callback = callback }

    func update(_ phase: DuplicateProgress.Phase, inspected: Int = 0, hashed: Int = 0,
                bytes: UInt64 = 0, candidates: Int? = nil, force: Bool = false) {
        let value: DuplicateProgress? = lock.withLock {
            self.inspected += inspected; self.hashed += hashed; self.bytes += bytes
            if let candidates { self.candidates = candidates }
            let now = Date()
            guard force || now.timeIntervalSince(lastEmission) >= 0.1 else { return nil }
            lastEmission = now
            return DuplicateProgress(phase: phase, inspectedFiles: self.inspected,
                hashedFiles: self.hashed, hashCandidates: self.candidates, bytesRead: self.bytes)
        }
        if let value { callback(value) }
    }
}
