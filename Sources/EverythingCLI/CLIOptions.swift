import Foundation
import IndexCore

struct CLIArgumentError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CLIOptions {
    enum Action { case search, help, version }
    var action: Action = .search
    var query = Query(text: "")
    var cacheURL: URL = defaultCacheURL
    var folderPath: String?
    var sort: QueryEngine.SortKey = .name
    var ascending = true
    var limit: Int?
    var format: CatalogFormat?
    var nullSeparated = false

    // Source: App/Sources/IndexActor.swift cacheURL(), without its directory
    // creation. A CLI invocation only reads the saved index.
    static var defaultCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Everything-Mac", isDirectory: true).appendingPathComponent("index.idx")
    }

    static func parse(_ arguments: [String]) throws -> CLIOptions {
        var options = CLIOptions(), words: [String] = [], index = 0, positional = false
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if positional { words.append(argument); continue }
            if argument == "--" { positional = true; continue }
            if !argument.hasPrefix("-") || argument == "-" { words.append(argument); continue }
            let pieces = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let flag = String(pieces[0])
            let inline = pieces.count == 2 ? String(pieces[1]) : nil
            // Source: this parser's submitted argv and option validation guards.
            func value() throws -> String {
                if let inline {
                    guard !inline.isEmpty else { throw CLIArgumentError(message: "\(flag) requires a value.") }
                    return inline
                }
                guard index < arguments.count, arguments[index] != "--" else {
                    throw CLIArgumentError(message: "\(flag) requires a value.")
                }
                let result = arguments[index]; index += 1
                guard !result.isEmpty else { throw CLIArgumentError(message: "\(flag) requires a value.") }
                return result
            }
            let valueFlags = ["--cache", "--folder", "--sort", "--limit", "-n", "--format"]
            if inline != nil && !valueFlags.contains(flag) {
                throw CLIArgumentError(message: "\(flag) does not accept a value.")
            }
            switch flag {
            case "--help", "-h": options.action = .help
            case "--version": options.action = .version
            case "--cache":
                let path = try value()
                options.cacheURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            case "--folder": options.folderPath = try value()
            case "--sort":
                let name = try value()
                switch name {
                case "name": options.sort = .name
                case "path": options.sort = .path
                case "size": options.sort = .size
                case "modified", "mtime": options.sort = .mtime
                case "kind": options.sort = .kind
                case "relevance": options.sort = .relevance
                default: throw CLIArgumentError(message: "Unsupported sort: \(name). Use name, path, size, modified, kind, or relevance.")
                }
            case "--descending", "--desc": options.ascending = false
            case "--ascending", "--asc": options.ascending = true
            case "--limit", "-n":
                let text = try value()
                guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let limit = Int(text) else {
                    throw CLIArgumentError(message: "\(flag) requires a nonnegative integer: \(text)")
                }
                options.limit = limit
            case "--format":
                let name = try value()
                if name == "paths" { options.format = nil }
                else if let format = CatalogFormat(rawValue: name) { options.format = format }
                else { throw CLIArgumentError(message: "Unsupported format: \(name). Use paths, json, csv, tsv, txt, or efu.") }
            case "--null", "-0": options.nullSeparated = true
            case "--match-path", "-p": options.query.matchPath = true
            case "--case-sensitive", "-c": options.query.caseInsensitive = false
            case "--ignore-case", "-i": options.query.caseInsensitive = true
            case "--whole-word", "-w": options.query.wholeWord = true
            case "--fuzzy", "-f": options.query.fuzzy = true
            case "--regex", "-r": options.query.regex = true
            case "--diacritic-insensitive", "-d": options.query.diacriticInsensitive = true
            case "--prefix": options.query.matchPrefix = true
            case "--suffix": options.query.matchSuffix = true
            case "--ignore-punctuation": options.query.ignorePunctuation = true
            case "--ignore-whitespace": options.query.ignoreWhitespace = true
            default: throw CLIArgumentError(message: "Unknown option: \(argument)")
            }
        }
        if options.nullSeparated && options.format != nil {
            throw CLIArgumentError(message: "--null requires --format paths.")
        }
        options.query.text = words.joined(separator: " ")
        return options
    }

    // Source: CLIOptions' implemented flag definitions, Query's public modifier
    // properties, shared QuerySyntax/QueryPredicate validation, and IndexActor's
    // cache path above. Help examples describe those APIs, not indexed records.
    static let help = """
    Usage: everything [options] [--] [query ...]

    Search EverythingMac's saved index. No disk scan or cache write is performed.
    An omitted query returns all live cached entries; no result limit is imposed.
    Quote queries in the shell to protect operators, wildcards and literal quotes.

    --cache PATH         Read this cache instead of the app's saved index
    --folder PATH        Descendants of this exact indexed folder (excludes folder)
    --sort KEY           name (default), path, size, modified, kind, relevance
    --descending         Reverse the selected sort; relevance ranks worst first
    --ascending          Ascending sort / best relevance first (default)
    --limit N, -n N      Emit at most N matches (0 emits none)
    --format FORMAT      paths (default), json, csv, tsv, txt, efu
    --null, -0           NUL-terminated raw paths for filename-safe pipelines
    --match-path, -p     Match the full cached path
    --case-sensitive, -c Match case (default ignores case)
    --ignore-case, -i    Ignore case
    --whole-word, -w     Match whole words
    --fuzzy, -f          Use the shared fuzzy matcher
    --regex, -r          Treat the query as a regular expression
    --diacritic-insensitive, -d  Ignore diacritics
    --prefix             Match the beginning of the text
    --suffix             Match the end of the text
    --ignore-punctuation Ignore punctuation while matching
    --ignore-whitespace  Ignore whitespace while matching
    --help, -h           Show this help
    --version            Show IndexCore.version
    --                   Treat all following arguments as query text

    Query syntax: quoted literals, * and ?, AND, OR, NOT, |, !, parentheses,
    name:, path:, parent:, ext:, file:, folder:, size:, dm:, date-modified:, regex:.
    Size comparisons/ranges support B/KB/MB/GB/TB and KiB/MiB/GiB/TiB.
    Modified-date comparisons/ranges support YYYY-MM-DD, today and yesterday.

    Default cache: ~/Library/Application Support/Everything-Mac/index.idx
    Output goes to stdout; diagnostics go to stderr. Use -0 for arbitrary names.
    TXT quotes embedded line breaks/quotes; CSV/TSV/EFU use catalog export fields.
    Metadata comes only from cached native fields; absent created dates stay absent.

    Exit: 0 success (including no matches or a closed pipe), 2 argument/query error,
          3 cache read/validation error, 4 scope/output error, 130 SIGINT, 143 SIGTERM.
    """ + "\n"
}
