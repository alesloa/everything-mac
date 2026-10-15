import Foundation

struct MCPInputError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct MCPOptions {
    enum Action { case serve, help, version }
    var action: Action = .serve
    var cacheURL = defaultCacheURL

    // Source: App/Sources/IndexActor.swift cacheURL(), also used by CLIOptions.
    // Unlike the app, this accessor never creates a directory.
    static var defaultCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Everything-Mac", isDirectory: true).appendingPathComponent("index.idx")
    }

    static func parse(_ arguments: [String]) throws -> MCPOptions {
        var options = MCPOptions(), index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            // Source: submitted argv and these implemented option guards.
            switch argument {
            case "--help", "-h": options.action = .help
            case "--version": options.action = .version
            case "--cache":
                guard index < arguments.count, !arguments[index].isEmpty,
                      !arguments[index].hasPrefix("--") else {
                    throw MCPInputError(message: "--cache requires a path.")
                }
                options.cacheURL = URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath)
                index += 1
            default:
                if argument.hasPrefix("--cache="), argument.count > "--cache=".count {
                    let path = String(argument.dropFirst("--cache=".count))
                    options.cacheURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                } else {
                    throw MCPInputError(message: "Unknown option: \(argument)")
                }
            }
        }
        return options
    }

    // Source: options above, MCPToolDefinitions, MCPIndexService and the app's
    // published cache location. No live indexing state is inferred here.
    static let help = """
    Usage: everything-mcp [--cache PATH]

    Serve EverythingMac saved-index searches over MCP stdio.
    Tools: search_files, get_index_status. Each call reads the saved cache.
    The server does not scan, write the cache, or read file contents.

    --cache PATH   Use this saved IndexCache file instead of the app's cache
    --help, -h     Show this help
    --version      Show IndexCore.version

    Default cache: ~/Library/Application Support/Everything-Mac/index.idx
    In server mode stdout is reserved for newline-delimited MCP JSON-RPC.
    Configure an MCP client to launch this executable; no TCP port is opened.
    """
}
