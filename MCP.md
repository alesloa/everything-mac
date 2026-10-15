# MCP server

`everything-mcp` lets MCP-capable agents query EverythingMac through a local
stdio process. It uses the [official Swift MCP SDK](https://github.com/modelcontextprotocol/swift-sdk)
for initialization, version negotiation, tool discovery, JSON-RPC, cancellation,
and newline-delimited stdio transport. It opens no network port.

The server uses `IndexCore`, the same query parser and search engine as the app
and CLI. It reads the saved index on every tool call. It does not scan folders,
launch the app, change files, save the cache, or read file contents. Results can
lag behind the app's live state until the app saves its index, and cached paths
can refer to offline shares or files that no longer exist.

## Build and install

Build on macOS 14 or later with Swift 6.2 or newer. The SDK is pinned to 0.12.1;
`Package.resolved` records its dependencies, including packages requiring Swift 6.2.

The normal app build also bundles and signs the MCP server, then installs the app
into `/Applications`:

```sh
./scripts/build-dev.sh
/Applications/EverythingMac.app/Contents/MacOS/everything-mcp --version
```

Use `/Applications/EverythingMac.app/Contents/MacOS/everything-mcp` as the MCP
client command to keep the server with the installed app. The app and MCP helper
are separate processes; a client can launch the helper while the app is closed.

To install a standalone copy instead:

```sh
./scripts/install-mcp.sh
"$HOME/.local/bin/everything-mcp" --version
```

The installer builds a release binary and copies it into `~/.local/bin`. Pass
another bin directory as the first argument to the installer if needed. It does
not edit `PATH` or any agent's configuration. To build without installing:

```sh
swift build -c release --product everything-mcp
.build/release/everything-mcp --help
```

Run EverythingMac first to create its saved index. The default location, from
`App/Sources/IndexActor.swift`, is
`~/Library/Application Support/Everything-Mac/index.idx`. A server launched with
`--cache PATH` reads that file instead. The cache location is fixed at startup;
tool arguments cannot change it.

## Connect an agent

Configure the agent's MCP client to **launch a local stdio command**. Use the
absolute path to the installed `everything-mcp` executable. GUI clients may not
inherit your terminal's `PATH`, and JSON command fields do not expand `~`.
No URL, port, API key, shell wrapper, or separate background daemon is needed.

For clients using the common `mcpServers` JSON configuration, the shape is below.
Replace `/absolute/path/to/everything-mcp` with your installed executable's path;
this is a configuration placeholder, not a published application path.

```json
{
  "mcpServers": {
    "everything-mac": {
      "command": "/absolute/path/to/everything-mcp",
      "args": []
    }
  }
}
```

Clients with a different configuration format need the same command and argument
array. To select a different saved cache, set `args` to
`["--cache", "/absolute/path/to/index.idx"]`, replacing the cache placeholder too.
Restart or reconnect the client after adding the server. Agents without MCP can
use the existing [JSON CLI](COMMAND_LINE.md).

## Tools

Both tools advertise `readOnlyHint: true` and return a JSON object in
`structuredContent`, plus the same serialized JSON in a text content block for
older clients, as described by the [MCP tools specification](https://modelcontextprotocol.io/specification/2025-11-25/server/tools).

### `search_files`

`query` is a required string; an empty string matches all cached entries within
the result limit. The shared syntax includes quoted literals, wildcards,
AND/OR/NOT, parentheses, `name:`, `path:`, `parent:`, `ext:`, `file:`, `folder:`,
`size:`, `dm:`, `date-modified:`, and `regex:`. OR binds more tightly than AND,
as it does in the app. See [COMMAND_LINE.md](COMMAND_LINE.md) for query details.

| Argument | Behavior |
| --- | --- |
| `limit` | Integer from 0 to 1000; default 50. |
| `folder` | Exact indexed folder path; searches descendants, excludes the folder itself. |
| `sort` | `name` (default), `path`, `size`, `modified`, `kind`, or `relevance`. |
| `descending` | Reverse the selected sort; fuzzy relevance then ranks worst first. |
| `match_path`, `case_sensitive`, `whole_word`, `fuzzy`, `regex` | Shared query modifiers; all default to false. |
| `diacritic_insensitive`, `prefix`, `suffix`, `ignore_punctuation`, `ignore_whitespace` | Additional shared query modifiers; all default to false. |

Example tool arguments, using the implemented query syntax:

```json
{"query": "ext:pdf size:>1MiB", "limit": 20, "sort": "modified", "descending": true}
```

Results contain `cache_path`, `results`, `returned`, `limit`, and `has_more`.
Each result contains only `path`, `size`, `modified` (`seconds`/`nanoseconds`),
and `directory`, taken from the loaded `FileStore` fields. Native mtimes have
whole-second precision, so their nanoseconds component is zero. Creation dates,
native attributes, file contents, and internal record IDs are not published.
Unsigned sizes above the SDK's signed `Int.max` are returned as exact decimal
strings; other sizes are JSON integers. Zero sizes and timestamps stay zero.

The server requests one extra matching ID to calculate `has_more`; it does not
invent a total match count. A zero limit returns no rows but still reports
whether matches exist. Refine the query or increase the limit when `has_more`
is true.

For large indexes, narrow the query or folder scope before sorting by full path.
The shared engine still considers all matches when choosing the first `limit`
results; a small response limit does not bound the work of a whole-index sort.

### `get_index_status`

Accepts an empty object and reads the configured cache. It returns `cache_path`,
`indexed_entries` (saved live entries, excluding deleted rows), and
`scan_completed` (the saved `FileStore.scanCompleted` flag). These values are
from the loaded snapshot, not the running app's current indexing state.

## Errors and lifecycle

Invalid arguments, query/scope validation failures, and actual cache read errors
return `isError: true` with the originating diagnostic. Unknown tools and methods
use JSON-RPC errors. A missing or corrupt cache does not prevent initialization
or tool discovery; tool calls report the failure and can recover after a valid
cache is saved. No stale snapshot is used after a cache read failure.

Only MCP messages go to stdout in server mode. Startup failures go to stderr.
The process exits when the client closes stdin; clients can also terminate it
with their normal subprocess lifecycle. `--help` and `--version` print their
requested output and exit without starting the transport.

## Tests

```sh
./scripts/test-mcp.sh
```

To exercise the actual installed app's helper with the same isolated fixtures:

```sh
EVERYTHING_MCP_BINARY=/Applications/EverythingMac.app/Contents/MacOS/everything-mcp ./scripts/test-mcp.sh
```

The tests launch real server processes with isolated temporary `IndexCache`
files. They exercise initialization with current and older protocol versions,
tool schemas and annotations, structured/text results, Unicode and embedded
delimiters, exact numeric metadata, sorting and folder boundaries, limits,
recoverable errors, cache replacement without restart, unchanged cache bytes,
and clean exit after stdin closes. They never use the owner's index.
