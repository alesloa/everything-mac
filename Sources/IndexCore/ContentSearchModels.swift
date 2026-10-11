import Foundation

/// Values are explicit content-search configuration, never inferred support data.
public struct ContentSearchOptions: Sendable {
    public var caseInsensitive = true
    public var diacriticInsensitive = false
    public var allowsNetwork = false
    public var maxFileBytes = 16 * 1_024 * 1_024
    public var concurrency = 2
    public var maxPDFPages = 100
    public var maxResults = 5_000
    public var chunkBytes = 64 * 1_024
    public var fileKind = ContentSearchFileKind.all
    public init() {}

    func validated() throws -> Self {
        guard (1...512 * 1_024 * 1_024).contains(maxFileBytes), (1...8).contains(concurrency),
              (1...2_000).contains(maxPDFPages), (1...100_000).contains(maxResults),
              (1...1_024 * 1_024).contains(chunkBytes) else {
            throw ContentSearchValidationError.invalidConfiguration
        }
        return self
    }
}

public enum ContentSearchFileKind: String, CaseIterable, Sendable {
    case all, text, pdf
    static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "csv", "tsv", "log", "json", "jsonl", "xml", "yaml", "yml",
        "toml", "ini", "cfg", "conf", "html", "htm", "css", "scss", "sass", "js", "jsx", "ts", "tsx",
        "swift", "c", "h", "m", "mm", "cpp", "hpp", "cc", "rs", "go", "py", "rb", "java", "kt",
        "sh", "zsh", "bash", "sql", "vue", "svelte", "tex", "plist", "strings", "gitignore"
    ]
    func supports(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        let text = Self.textExtensions.contains(ext) || ["makefile", "dockerfile", "license", "readme"]
            .contains((path as NSString).lastPathComponent.lowercased())
        return self == .all ? text || ext == "pdf" : self == .pdf ? ext == "pdf" : text
    }
}

public struct ContentSearchRequest: Sendable {
    public var literal: String
    public var filenameQuery: Query?
    public var restrictToFilenameQuery: Bool
    public var folderPath: String?
    public var pickedFolderPath: String?
    public var options: ContentSearchOptions
    public init(literal: String, filenameQuery: Query? = nil, restrictToFilenameQuery: Bool = false,
                folderPath: String? = nil, pickedFolderPath: String? = nil,
                options: ContentSearchOptions = ContentSearchOptions()) {
        self.literal = literal; self.filenameQuery = filenameQuery
        self.restrictToFilenameQuery = restrictToFilenameQuery; self.folderPath = folderPath
        self.pickedFolderPath = pickedFolderPath; self.options = options
    }
}

/// Each hit carries actual descriptor metadata and an unchanged-file check made
/// after extraction. This is a read-time snapshot, not a promise of future stability.
public struct ContentSearchHit: Sendable, Equatable, Identifiable {
    public var id: [UInt8] { Array(path.utf8) }
    public let path: String
    public let occurrenceCount: Int
    public let excerpt: String
    public let fileBytes: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
}

public struct ContentSearchFileError: Sendable, Equatable, Identifiable {
    public var id: [UInt8] { Array(path.utf8) }
    public let path: String
    /// Source: Foundation's actual localizedDescription for a caught I/O error.
    public let message: String
}

public struct ContentSearchProgress: Sendable {
    public var candidates = 0
    public var completed = 0
    public var searched = 0
    public var skipped = 0
    public var matchingFiles = 0
    public var bytesRead: Int64 = 0
    public var results: [ContentSearchHit] = []
    public var errors: [ContentSearchFileError] = []
    public var finished = false
    public var cancelled = false
    public var failure: String?
    public init() {}
}

enum ContentSearchValidationError: LocalizedError {
    case invalidLiteral, invalidConfiguration, missingQuery
    // Source: this service's explicit validation bounds and required validated scope.
    var errorDescription: String? {
        switch self {
        case .invalidLiteral: "Enter a literal containing 1–1,024 Unicode scalars."
        case .invalidConfiguration: "The content-search settings exceed the supported bounds."
        case .missingQuery: "Current filename query scope requires a validated query."
        }
    }
}
