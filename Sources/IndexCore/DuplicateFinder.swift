import Foundation
import Darwin
import CryptoKit

public struct DuplicateFinder: Sendable {
    static let jobLimiter = BackgroundFileJobLimiter(maximumActive: 2)
    public init() {}

    public func find(in scope: DuplicateScope, method: DuplicateMethod = .contents,
                     options: DuplicateOptions = .init(),
                     progress: @escaping @Sendable (DuplicateProgress) -> Void = { _ in }) async -> DuplicateReport {
        await find(in: scope, method: method, options: options, progress: progress, observer: { _ in })
    }

    func find(in scope: DuplicateScope, method: DuplicateMethod, options: DuplicateOptions,
              progress: @escaping @Sendable (DuplicateProgress) -> Void,
              observer: @escaping @Sendable (DuplicateObservation) -> Void) async -> DuplicateReport {
        let cancellation = DuplicateCancellation()
        return await withTaskCancellationHandler {
            if Task.isCancelled { cancellation.cancel() }
            let worker = Task.detached(priority: .utility) {
                await Self.jobLimiter.withPermit(cancellation: cancellation, cancelled: {
                    DuplicateReport(method: method, groups: [], inspectedFiles: 0, hashedFiles: 0,
                                    skipped: [], cancelled: true)
                }) {
                    let reporter = DuplicateProgressReporter(callback: progress)
                    reporter.update(.inspecting, force: true)
                    let access = DuplicateFileAccess(options: options)
                    var inventory = DuplicateInventory.collect(scope, access: access,
                        cancellation: cancellation, progress: reporter)
                    let grouped = Dictionary(grouping: inventory.files, by: { $0.size })
                    let candidates = grouped.values.filter { $0.count > 1 }.flatMap { $0 }
                    var hashes: [DuplicateFile: String] = [:]
                    if case .contents = method {
                        let result = await Self.hash(candidates, access: access, cancellation: cancellation,
                                                     reporter: reporter, observer: observer)
                        hashes = result.hashes
                        inventory.skipped.append(contentsOf: result.skipped)
                    }
                    observer(.beforeFinalValidation)
                    reporter.update(.validating, force: true)
                    var groups: [GroupKey: [DuplicateFile]] = [:]
                    for file in inventory.files {
                        if cancellation.isCancelled { break }
                        let key: GroupKey
                        switch method {
                        case .nameAndSize: key = .name(Array(file.name.utf8), file.size)
                        case .contents:
                            guard let digest = hashes[file] else { continue }
                            key = .digest(digest, file.size)
                        }
                        guard access.revalidate(file) else { inventory.skip(file.path, .changed); continue }
                        groups[key, default: []].append(file)
                    }
                    let result = cancellation.isCancelled ? [] : groups.compactMap { key, files -> DuplicateGroup? in
                        guard files.count > 1 else { return nil }
                        let digest: String? = if case .digest(let value, _) = key { value } else { nil }
                        return DuplicateGroup(files: files.sorted(by: Self.pathOrder), sha256: digest)
                    }.sorted { left, right in
                        if left.size != right.size { return left.size > right.size }
                        return Self.pathOrder(left.files[0], right.files[0])
                    }
                    reporter.update(.finished, force: true)
                    return DuplicateReport(method: method, groups: result, inspectedFiles: inventory.files.count,
                        hashedFiles: hashes.count, skipped: inventory.skipped, cancelled: cancellation.isCancelled)
                }
            }
            return await worker.value
        } onCancel: { cancellation.cancel() }
    }

    private enum GroupKey: Hashable { case name([UInt8], UInt64); case digest(String, UInt64) }

    struct HashResult: Sendable {
        var hashes: [DuplicateFile: String] = [:]
        var skipped: [DuplicateSkippedFile] = []
    }

    static func hash(_ files: [DuplicateFile], access: DuplicateFileAccess,
                     cancellation: DuplicateCancellation, reporter: DuplicateProgressReporter,
                     observer: @escaping @Sendable (DuplicateObservation) -> Void) async -> HashResult {
        reporter.update(.hashing, candidates: files.count, force: true)
        return await withTaskGroup(of: (DuplicateFile, String?).self, returning: HashResult.self) { group in
            var next = 0
            var result = HashResult()
            func enqueue(_ file: DuplicateFile) {
                group.addTask {
                    (file, hashFile(file, access: access, cancellation: cancellation,
                                    reporter: reporter, observer: observer))
                }
            }
            while next < min(access.options.workers, files.count), !cancellation.isCancelled {
                enqueue(files[next]); next += 1
            }
            while let (file, digest) = await group.next() {
                if let digest { result.hashes[file] = digest }
                else if !cancellation.isCancelled { result.skipped.append(.init(path: file.path, reason: .changed)) }
                if next < files.count, !cancellation.isCancelled {
                    enqueue(files[next]); next += 1
                }
            }
            return result
        }
    }

    private static func hashFile(_ file: DuplicateFile, access: DuplicateFileAccess,
                                 cancellation: DuplicateCancellation, reporter: DuplicateProgressReporter,
                                 observer: @Sendable (DuplicateObservation) -> Void) -> String? {
        guard !cancellation.isCancelled, let descriptor = access.openFile(file) else { return nil }
        defer { close(descriptor) }
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: access.options.chunkBytes)
        var consumed: UInt64 = 0
        while !cancellation.isCancelled {
            var currentMetadata = stat()
            guard fstat(descriptor, &currentMetadata) == 0,
                  currentMetadata.st_flags & UInt32(SF_DATALESS) == 0,
                  DuplicateFileAccess.fingerprint(currentMetadata) == file.fingerprint else { return nil }
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            guard consumed <= file.size, UInt64(count) <= file.size - consumed else { return nil }
            buffer.withUnsafeBytes { digest.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            consumed += UInt64(count)
            reporter.update(.hashing, bytes: UInt64(count))
            observer(.chunkRead(path: file.path, bytes: consumed))
        }
        var finalMetadata = stat()
        guard !cancellation.isCancelled, consumed == file.size, fstat(descriptor, &finalMetadata) == 0,
              DuplicateFileAccess.fingerprint(finalMetadata) == file.fingerprint,
              access.revalidate(file) else { return nil }
        let value = digest.finalize().map { String(format: "%02x", $0) }.joined()
        reporter.update(.hashing, hashed: 1)
        observer(.hashed(file.path))
        return value
    }

    static func pathOrder(_ left: DuplicateFile, _ right: DuplicateFile) -> Bool {
        left.path.utf8.lexicographicallyPrecedes(right.path.utf8)
    }
}

enum DuplicateObservation: Sendable {
    case chunkRead(path: String, bytes: UInt64)
    case hashed(String)
    case beforeFinalValidation
}
