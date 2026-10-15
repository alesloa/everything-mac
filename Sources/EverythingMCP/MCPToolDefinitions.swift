import MCP

enum MCPToolDefinitions {
    static let defaultLimit = 50
    static let maximumLimit = 1000

    // Source: Query's public modifiers and their mapping in MCPIndexService.
    static let booleanOptions: [String: String] = [
        "descending": "Reverse the sort order; fuzzy relevance then ranks worst first.",
        "match_path": "Match the full cached path instead of only the name.",
        "case_sensitive": "Match case; default matching ignores case.",
        "whole_word": "Match whole words.",
        "fuzzy": "Use the shared fuzzy matcher; select sort=relevance for best matches first.",
        "regex": "Treat the query as a regular expression.",
        "diacritic_insensitive": "Ignore diacritics.",
        "prefix": "Match the beginning of the text.",
        "suffix": "Match the end of the text.",
        "ignore_punctuation": "Ignore punctuation while matching.",
        "ignore_whitespace": "Ignore whitespace while matching.",
    ]

    static let searchProperties: [String: Value] = {
        // Source: QuerySyntax/QueryPredicate, CatalogNativeScope and the search
        // implementation below, including this server's explicit response limits.
        var properties: [String: Value] = [
            "query": ["type": "string", "description": .string("EverythingMac query: quoted literals, wildcards, AND/OR/NOT, "
                + "name:, path:, parent:, ext:, file:, folder:, size:, dm:, date-modified:, regex:. "
                + "OR binds more tightly than AND. An empty string matches all cached entries.")],
            "folder": ["type": "string", "minLength": 1,
                "description": "Exact indexed folder path; includes descendants and excludes the folder itself."],
            "sort": ["type": "string", "enum": ["name", "path", "size", "modified", "kind", "relevance"],
                "default": "name"],
            "limit": ["type": "integer", "minimum": 0, "maximum": .int(maximumLimit),
                "default": .int(defaultLimit)],
        ]
        for (name, description) in booleanOptions {
            properties[name] = ["type": "boolean", "default": false, "description": .string(description)]
        }
        return properties
    }()

    static func objectSchema(_ properties: [String: Value], required: [String]? = nil) -> Value {
        ["type": "object", "properties": .object(properties), "additionalProperties": false,
         "required": .array((required ?? properties.keys.sorted()).map(Value.string))]
    }

    // Source: only FileStore's saved path, UInt64 size, whole-second mtime and
    // directory bit are exposed by MCPIndexService. Larger unsigned sizes stay
    // decimal strings because the SDK's integer Value is a signed platform Int.
    static let rowSchema = objectSchema([
        "path": ["type": "string"],
        "size": ["type": ["integer", "string"],
            "description": "Cached byte size; unsigned values above Int.max are exact decimal strings."],
        "modified": objectSchema(["seconds": ["type": "integer"], "nanoseconds": ["type": "integer"]]),
        "directory": ["type": "boolean"],
    ])

    // Source: these tool implementations, the shared search API and saved-cache
    // fields. Hints describe the read-only behavior of these two handlers.
    static let tools: [Tool] = [
        Tool(name: "search_files",
             description: "Search EverythingMac's saved filename index with the same query parser as the app. "
                + "Returns cached paths and metadata, not file contents or live filesystem checks. "
                + "has_more reports whether matches were omitted by the requested limit.",
             inputSchema: objectSchema(searchProperties, required: ["query"]),
             annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false),
             outputSchema: objectSchema([
                "cache_path": ["type": "string"],
                "results": ["type": "array", "items": rowSchema],
                "returned": ["type": "integer"], "limit": ["type": "integer"],
                "has_more": ["type": "boolean"],
             ])),
        Tool(name: "get_index_status",
             description: "Read the configured saved index and report its path, live cached entry count and saved "
                + "scan-completed flag. This does not report the running app's indexing state or file availability.",
             inputSchema: objectSchema([:]),
             annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false),
             outputSchema: objectSchema([
                "cache_path": ["type": "string"], "indexed_entries": ["type": "integer"],
                "scan_completed": ["type": "boolean"],
             ])),
    ]
}
