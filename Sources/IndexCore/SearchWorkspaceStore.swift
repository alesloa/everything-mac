import Foundation

public enum SearchWorkspaceStoreError: Error, LocalizedError, Sendable {
    case unsupportedVersion(Int), oversized

    // Source: messages reflect the decoded archive version and this store's explicit file-size limit.
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "The saved workspace format version \(version) is not supported."
        case .oversized: "The saved workspace file exceeds the application's size limit."
        }
    }
}

public struct SearchWorkspaceStore: Sendable {
    public let url: URL
    public static let maximumFileBytes = 16 * 1024 * 1024

    public init(url: URL) { self.url = url }

    public static func decode(_ data: Data, at date: Date = Date()) throws -> SearchWorkspaceArchive {
        guard data.count <= maximumFileBytes else { throw SearchWorkspaceStoreError.oversized }
        var archive = try JSONDecoder().decode(SearchWorkspaceArchive.self, from: data)
        guard archive.version == 1 else { throw SearchWorkspaceStoreError.unsupportedVersion(archive.version) }
        archive.normalize(at: date)
        return archive
    }

    public static func encode(_ archive: SearchWorkspaceArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        guard data.count <= maximumFileBytes else { throw SearchWorkspaceStoreError.oversized }
        return data
    }

    public func load(at date: Date = Date()) throws -> SearchWorkspaceArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return SearchWorkspaceArchive() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > Self.maximumFileBytes { throw SearchWorkspaceStoreError.oversized }
        return try Self.decode(Data(contentsOf: url), at: date)
    }

    public func save(_ archive: SearchWorkspaceArchive) throws {
        let data = try Self.encode(archive)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
