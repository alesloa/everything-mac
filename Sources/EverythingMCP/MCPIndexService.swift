import Foundation
import IndexCore
import MCP

// Serialize index work separately from the SDK's protocol actor, so pings and
// cancellation notifications can still be processed during a search.
actor MCPIndexService {
    let cacheURL: URL
    init(cacheURL: URL) { self.cacheURL = cacheURL }

    func call(name: String, arguments: [String: Value],
              isCancelled: @escaping @Sendable () -> Bool) throws -> Value {
        try Task.checkCancellation()
        if name == "get_index_status" {
            try rejectUnknown(arguments, allowed: [])
            let store = try load()
            // Source: the selected cache URL and the loaded FileStore's native
            // count/deletion count and saved scanCompleted field.
            return ["cache_path": .string(cacheURL.path),
                    "indexed_entries": .int(store.count - store.deletedCount),
                    "scan_completed": .bool(store.scanCompleted)]
        }
        try rejectUnknown(arguments, allowed: Set(MCPToolDefinitions.searchProperties.keys))
        // Source: the actual submitted argument types and constraints published
        // in search_files' input schema. Invalid input never becomes a default.
        func string(_ key: String) throws -> String? {
            guard let value = arguments[key] else { return nil }
            guard case .string(let text) = value else {
                throw MCPInputError(message: "\(key) must be a string.")
            }
            return text
        }
        func boolean(_ key: String) throws -> Bool {
            guard let value = arguments[key] else { return false }
            guard case .bool(let flag) = value else {
                throw MCPInputError(message: "\(key) must be a boolean.")
            }
            return flag
        }
        guard let text = try string("query") else { throw MCPInputError(message: "query is required.") }
        let folder = try string("folder")
        if folder?.isEmpty == true { throw MCPInputError(message: "folder must not be empty.") }
        let limit: Int
        if let value = arguments["limit"] {
            guard case .int(let number) = value, (0...MCPToolDefinitions.maximumLimit).contains(number) else {
                throw MCPInputError(message: "limit must be an integer from 0 to \(MCPToolDefinitions.maximumLimit).")
            }
            limit = number
        } else { limit = MCPToolDefinitions.defaultLimit }
        let sort: QueryEngine.SortKey
        let sortName = try string("sort") ?? "name"
        switch sortName {
        case "name": sort = .name
        case "path": sort = .path
        case "size": sort = .size
        case "modified": sort = .mtime
        case "kind": sort = .kind
        case "relevance": sort = .relevance
        default: throw MCPInputError(message: "Unsupported sort: \(sortName). Use name, path, size, modified, kind, or relevance.")
        }
        let query = try Query(text: text, matchPath: boolean("match_path"), caseInsensitive: !boolean("case_sensitive"),
            wholeWord: boolean("whole_word"), fuzzy: boolean("fuzzy"), regex: boolean("regex"),
            diacriticInsensitive: boolean("diacritic_insensitive"), matchPrefix: boolean("prefix"),
            matchSuffix: boolean("suffix"), ignorePunctuation: boolean("ignore_punctuation"),
            ignoreWhitespace: boolean("ignore_whitespace"))
        let ascending = try !boolean("descending")
        if let error = query.validationError { throw error }
        let store = try load()
        let ids = try CatalogSearch.nativeIDs(store: store, query: query, sort: sort, ascending: ascending,
            limit: limit + 1, folderPath: folder, isCancelled: isCancelled)
        try Task.checkCancellation()
        let rows: [Value] = ids.prefix(limit).map { id in
            // Source: this IndexCache-loaded FileStore's actual fields, with no
            // filesystem probing or invented created dates, attributes or IDs.
            let size = store.size(of: id)
            return ["path": .string(store.path(of: id)),
                    "size": Int(exactly: size).map(Value.int) ?? .string(String(size)),
                    "modified": ["seconds": .int(Int(store.mtime(of: id))), "nanoseconds": 0],
                    "directory": .bool(store.isDir(of: id))]
        }
        // Source: selected URL, returned rows, submitted/default limit and the
        // extra matching ID requested above. No total match count is inferred.
        return ["cache_path": .string(cacheURL.path), "results": .array(rows),
                "returned": .int(rows.count), "limit": .int(limit), "has_more": .bool(ids.count > limit)]
    }

    private func load() throws -> FileStore {
        try Task.checkCancellation()
        do {
            // Reload each call: IndexCache.save replaces the cache atomically.
            // Each search retains its own immutable mmap, never a stale fallback.
            let store = try IndexCache.load(from: cacheURL, buildWriterIndex: false).0
            try Task.checkCancellation()
            return store
        } catch is CancellationError { throw CancellationError() }
        catch {
            // Source: configured path plus the actual cache/filesystem diagnostic.
            throw MCPInputError(message: "\(cacheURL.path): \(error.localizedDescription)")
        }
    }

    private func rejectUnknown(_ arguments: [String: Value], allowed: Set<String>) throws {
        if let key = arguments.keys.sorted().first(where: { !allowed.contains($0) }) {
            // Source: the submitted argument and this tool's declared schema.
            throw MCPInputError(message: "Unknown argument: \(key)")
        }
    }
}

// The engine also checks cancellation on Dispatch workers, where Task.isCancelled
// does not inherit the SDK handler task's state. Bridge it with a locked flag.
final class MCPWorkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
