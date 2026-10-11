import Foundation

public struct FolderComparisonEntry: Sendable, Identifiable {
    public enum Status: Sendable { case sameContents, differentContents, onlyLeft, onlyRight, unverified }
    public var id: [UInt8] { Array(relativePath.utf8) }
    public let relativePath: String
    public let leftPath: String?
    public let rightPath: String?
    public let leftSize: UInt64?
    public let rightSize: UInt64?
    public let status: Status
    public let sha256: String?
}

public struct FolderComparisonReport: Sendable {
    public let leftRoot: String
    public let rightRoot: String
    public let entries: [FolderComparisonEntry]
    public let inspectedFiles: Int
    public let hashedFiles: Int
    public let skipped: [DuplicateSkippedFile]
    public let cancelled: Bool
}

extension DuplicateFinder {
    public func compareFolders(_ left: String, _ right: String, options: DuplicateOptions = .init(),
                               progress: @escaping @Sendable (DuplicateProgress) -> Void = { _ in }) async -> FolderComparisonReport {
        await compareFolders(left, right, options: options, progress: progress, observer: { _ in })
    }

    func compareFolders(_ left: String, _ right: String, options: DuplicateOptions,
                        progress: @escaping @Sendable (DuplicateProgress) -> Void,
                        observer: @escaping @Sendable (DuplicateObservation) -> Void) async -> FolderComparisonReport {
        let cancellation = DuplicateCancellation()
        return await withTaskCancellationHandler {
            if Task.isCancelled { cancellation.cancel() }
            let worker = Task.detached(priority: .utility) {
                await Self.jobLimiter.withPermit(cancellation: cancellation, cancelled: {
                    FolderComparisonReport(leftRoot: left, rightRoot: right, entries: [],
                        inspectedFiles: 0, hashedFiles: 0, skipped: [], cancelled: true)
                }) {
                    let reporter = DuplicateProgressReporter(callback: progress)
                    reporter.update(.inspecting, force: true)
                    let access = DuplicateFileAccess(options: options)
                    let leftRoot = Scanner.normalizedRoot(left)
                    let rightRoot = Scanner.normalizedRoot(right)
                    let leftInventory = DuplicateInventory.collect(.folder(leftRoot), access: access,
                        cancellation: cancellation, progress: reporter)
                    let rightInventory = DuplicateInventory.collect(.folder(rightRoot), access: access,
                        cancellation: cancellation, progress: reporter)
                    let leftFiles = Self.relativeFiles(leftInventory.files, root: leftRoot)
                    let rightFiles = Self.relativeFiles(rightInventory.files, root: rightRoot)
                    var candidateIDs = Set<[UInt8]>()
                    var candidates: [DuplicateFile] = []
                    for (relative, file) in leftFiles {
                        guard let other = rightFiles[relative], file.size == other.size else { continue }
                        for candidate in [file, other] where candidateIDs.insert(candidate.id).inserted {
                            candidates.append(candidate)
                        }
                    }
                    let hashed = await Self.hash(candidates, access: access, cancellation: cancellation,
                                                  reporter: reporter, observer: observer)
                    var skipped = leftInventory.skipped + rightInventory.skipped + hashed.skipped
                    let leftOmitted = Self.relativeSkipped(leftInventory.skipped, root: leftRoot)
                    let rightOmitted = Self.relativeSkipped(rightInventory.skipped, root: rightRoot)
                    let relatives = Set(leftFiles.keys).union(rightFiles.keys).union(leftOmitted.keys).union(rightOmitted.keys)
                    var entries: [FolderComparisonEntry] = []
                    observer(.beforeFinalValidation)
                    reporter.update(.validating, force: true)
                    for relative in relatives.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                        if cancellation.isCancelled { break }
                        let lhs = leftFiles[relative]
                        let rhs = rightFiles[relative]
                        var valid = true
                        for file in [lhs, rhs].compactMap({ $0 }) where !access.revalidate(file) {
                            valid = false
                            skipped.append(.init(path: file.path, reason: .changed))
                        }
                        let status: FolderComparisonEntry.Status
                        var digest: String?
                        if !valid || Self.hasOmittedAncestor(relative, omitted: leftOmitted)
                            || Self.hasOmittedAncestor(relative, omitted: rightOmitted) {
                            status = .unverified
                        } else if let lhs, let rhs {
                            if lhs.size != rhs.size { status = .differentContents }
                            else if let leftHash = hashed.hashes[lhs], let rightHash = hashed.hashes[rhs] {
                                status = leftHash == rightHash ? .sameContents : .differentContents
                                if leftHash == rightHash { digest = leftHash }
                            } else { status = .unverified }
                        } else if lhs != nil {
                            let opposite = (rightRoot == "/" ? "/" : rightRoot + "/") + String(decoding: relative, as: UTF8.self)
                            status = !rightInventory.incomplete && access.absenceIsVerified(opposite) ? .onlyLeft : .unverified
                        } else if rhs != nil {
                            let opposite = (leftRoot == "/" ? "/" : leftRoot + "/") + String(decoding: relative, as: UTF8.self)
                            status = !leftInventory.incomplete && access.absenceIsVerified(opposite) ? .onlyRight : .unverified
                        }
                        else { status = .unverified }
                        entries.append(FolderComparisonEntry(relativePath: String(decoding: relative, as: UTF8.self),
                            leftPath: lhs?.path ?? leftOmitted[relative], rightPath: rhs?.path ?? rightOmitted[relative],
                            leftSize: lhs?.size, rightSize: rhs?.size, status: status, sha256: digest))
                    }
                    reporter.update(.finished, force: true)
                    return FolderComparisonReport(leftRoot: leftRoot, rightRoot: rightRoot,
                        entries: cancellation.isCancelled ? [] : entries,
                        inspectedFiles: leftInventory.files.count + rightInventory.files.count,
                        hashedFiles: hashed.hashes.count, skipped: skipped, cancelled: cancellation.isCancelled)
                }
            }
            return await worker.value
        } onCancel: { cancellation.cancel() }
    }

    private static func relativeFiles(_ files: [DuplicateFile], root: String) -> [[UInt8]: DuplicateFile] {
        Dictionary(files.compactMap { file in relativePath(file.path, root: root).map { ($0, file) } },
                   uniquingKeysWith: { first, _ in first })
    }

    private static func relativeSkipped(_ files: [DuplicateSkippedFile], root: String) -> [[UInt8]: String] {
        Dictionary(files.compactMap { file in relativePath(file.path, root: root).map { ($0, file.path) } },
                   uniquingKeysWith: { first, _ in first })
    }

    private static func relativePath(_ path: String, root: String) -> [UInt8]? {
        let prefix = Array((root == "/" ? "/" : root + "/").utf8)
        guard path.utf8.starts(with: prefix), path.utf8.count > prefix.count else { return nil }
        return Array(path.utf8.dropFirst(prefix.count))
    }

    private static func hasOmittedAncestor(_ relative: [UInt8], omitted: [[UInt8]: String]) -> Bool {
        omitted.keys.contains { relative == $0 || relative.starts(with: $0 + [47]) }
    }
}
