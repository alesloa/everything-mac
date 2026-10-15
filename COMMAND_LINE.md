# Command-line search

`everything` reads the index saved by EverythingMac, using the same `IndexCore`
query parser, modifiers, fuzzy ranking and sort functions as the app. It does not
scan folders, connect to shares, start the app, or save the index. The saved
snapshot can lag behind the app's live results until the app saves its cache.

Build on macOS 14 or later with Swift 6.2:

```sh
swift build -c release --product everything
.build/release/everything --help
```

To install a copy, choose a directory you own. This example uses `~/.local/bin`:

```sh
mkdir -p "$HOME/.local/bin"
cp .build/release/everything "$HOME/.local/bin/everything"
"$HOME/.local/bin/everything" --version
```

The commands do not change your `PATH`. Use the full binary path, or a bin
directory already on your `PATH`.

The default cache path comes from `App/Sources/IndexActor.swift`:
`~/Library/Application Support/Everything-Mac/index.idx`. Run the app to create
its index before using the CLI. `--cache PATH` selects another saved `IndexCache`
file, including an isolated test fixture. A missing or corrupt cache produces a
diagnostic and exits; the CLI never repairs or replaces it.

```sh
# Filename search; shell quotes preserve the shared query syntax.
everything 'ext:pdf size:>1MiB'
everything '(ext:pdf OR ext:docx) NOT folder:'
everything --regex '^report.*\.pdf$'
everything --fuzzy --sort relevance --limit 20 'rpt'
everything --diacritic-insensitive --ignore-punctuation 'cafe-notes'

# Raw paths separated by NUL preserve spaces, tabs, quotes and embedded newlines.
everything -0 'ext:txt' | xargs -0 -n 1 printf '%s\n'

# Export every matching cached row in the requested sort order.
everything --sort modified --descending --format json 'ext:pdf' > results.json
everything --format efu 'ext:txt' > results.efu
```

For folder scope, pass an exact folder path that is present in the saved index:
`everything --folder "$folder" 'ext:txt'`. Scope follows the cache's actual parent
IDs, includes descendants at every depth, excludes the selected folder itself,
and excludes folders with similar path prefixes. It works with cached offline
folders without probing the filesystem. An absent folder or a file supplied as
a folder produces a scope error.

All matching live rows are emitted by default. `--limit N` explicitly selects the
first N sorted matches; `--limit 0` emits none. There is no app display cap on CLI
output. Sorting retains compact record IDs; each full row is reconstructed only
when emitted. Sort keys are `name` (default), `path`, `size`, `modified` (`mtime`
is an alias), `kind`, and `relevance`. `--descending` reverses the selected sort;
for fuzzy relevance it requests lower scores first.

The full shared query syntax supports quoted literals, `*`, `?`, `AND`, `OR`,
`NOT`, `|`, `!`, parentheses/angle groups, `name:`, `path:`, `parent:`, `ext:`,
`file:`, `folder:`, `size:`, `dm:`, `date-modified:`, and `regex:`. The shared parser
defines precedence: OR binds more tightly than AND. Size comparisons and ranges
use bytes, decimal KB/MB/GB/TB or binary KiB/MiB/GiB/TiB. Modified-date filters
accept calendar dates, `today`, and `yesterday` using the local calendar/timezone.
Pass `--` before query text beginning with a dash. Put literal double quotes
inside shell single quotes when a query term contains spaces, for example:
`everything '"annual report" ext:pdf'`.

Modifiers map directly to `Query` properties: `--match-path`, `--case-sensitive`,
`--ignore-case`, `--whole-word`, `--fuzzy`, `--regex`,
`--diacritic-insensitive`, `--prefix`, `--suffix`, `--ignore-punctuation`, and
`--ignore-whitespace`. The shared engine defines how combined modifiers behave.
Flags with values also support `--flag=value`; `--help` lists short aliases.

| Format | Representation and source |
| --- | --- |
| `paths` | Raw UTF-8 `FileStore.path(of:)`, followed by LF; `--null`/`-0` uses NUL. |
| `txt` | The shared catalog TXT serializer quotes paths containing quotes or line breaks; rows use CRLF. |
| `json` | The shared catalog JSON array contains `path`, `size`, `modified` (`seconds`/`nanoseconds`), and `directory`, from native cache fields. |
| `csv`, `tsv`, `efu` | The shared catalog serializer emits Filename, Size, Date Modified, Date Created, Attributes, and Directory columns; modified dates use exact FILETIME. |

Native metadata comes from `FileStore`'s saved `size`, `mtime`, and `isDir` fields.
The cache has no creation date or native attributes: JSON omits those fields and
tabular exports leave them empty. The shared EFU serializer uses its documented
directory attribute bit for a cached directory. A cached zero size or Unix-epoch
mtime stays zero because that value is present in the source. `--version` prints
the library's `IndexCore.version`.

Only data goes to stdout. Argument and shared query-parser errors, actual cache
validation/filesystem errors, scope errors, and output errors go to stderr.
`--null` applies only to `paths`. A closed downstream pipe exits quietly. SIGINT
or SIGTERM stops searching/output; a stream interrupted partway can be incomplete.

| Exit status | Meaning |
| --- | --- |
| 0 | Success, including no matches and a closed downstream pipe. |
| 2 | Invalid CLI arguments or shared query-parser diagnostic. |
| 3 | Cache read or binary validation failure. |
| 4 | Folder scope or output failure. |
| 130 / 143 | SIGINT / SIGTERM cancellation. |

Run the process regression suite with `./scripts/test-cli.sh`. It builds a release
binary and launches real processes against isolated cache fixtures, including
more than 5,000 results, Unicode and delimiter-heavy names, all output formats,
cache errors, sorting/scope, closed pipes and cancellation.

For MCP-capable agents, the separate `everything-mcp` executable exposes this
same saved-index query engine through stdio tools. See [MCP.md](MCP.md).
