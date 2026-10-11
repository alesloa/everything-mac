# Changelog

All notable changes to EverythingMac are recorded here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) (`MAJOR.MINOR.PATCH`).

## [0.5.0] - Unreleased

### Added
- Advanced query operators, regular expressions, metadata predicates, built-in file-type filters, and a visual query builder.
- Scheduled network-share refresh with per-share pause, cancel, manual refresh, and observed progress.
- Multi-file actions, file clipboard and drag-and-drop, copy/move destinations, single and batch rename, Finder Get Info, and guarded undo.
- Quick Look, a preview pane, and visible-result thumbnails with bounded background work.
- Saved searches, reusable query macros and filters, history, independent search tabs and windows, and session restoration.
- A menu bar item, a configurable global shortcut, and indexing after the last window closes.
- Exact query counts, match highlighting, persisted table columns, an indexed folder sidebar, and optional indexed folder totals.
- Portable file catalogs and selected, shown, or full-query exports in CSV, JSON, EFU, TXT, and TSV formats.
- Verified duplicate-file groups and folder comparison using streamed SHA-256 checks, without automatic deletion.
- Optional scoped content search for supported text, source, raw HTML, and PDF text, with cancellation and file-size limits.
- A read-only `everything` command-line tool using the saved index and shared query/export behavior. See [COMMAND_LINE.md](COMMAND_LINE.md).
- An index activity viewer with bounded observed events and actual scan, cache, and network status.

### Fixed
- Undo retains edited copies even when an in-place edit preserves the original byte count and restores the exact modification time.
- Switching search tabs clears the previous tab's match count and validation error until the new search completes.
- The content-search panel requires a valid filename query before offering scope controls.

## [0.4.0] - Unreleased

### Added
- Swift fuzzy filename search, relevance sorting, single-letter typo tolerance for longer ASCII terms, and a persisted switch back to substring matching.
- Full Disk Access onboarding before the first scan, with settings, relaunch, and continue-without-access actions.
- Opt-in network-volume indexing, background scans, offline cached search, and automatic reconnection using saved keychain credentials.
- Incremental query narrowing that rechecks the complete previous match set when a query extension cannot add matches.
- A background filename dictionary with character bitmaps that filters groups of 64 names and shares matching work across duplicate filenames.
- Memory-mapped index bases, small live-update overlays, streamed atomic cache saves, and background compaction that preserves record IDs and in-flight snapshots.

### Fixed
- Releasing or restarting the filesystem watcher now stops the previous stream and keeps in-flight callback data alive, preventing callbacks from reading freed memory.
- Concurrent mount-table reads use separate owned buffers; native file icons and file actions are confined to the main actor.
- Result rendering safely handles stale row requests and unsigned file sizes beyond the signed formatter's range without changing their values.
- Searches and file counts no longer queue behind directory reconciliation, network-tree merges, or cache serialization; queries use immutable snapshots on separate workers.
- Superseded searches stop scanning, and serial cache saves retain the last fully applied filesystem-event checkpoint and the snapshot's exclusion fingerprint.
- Live appends and deletions no longer copy the complete published index; canceled filename preparation releases obsolete mapped bases.
- Quitting permission onboarding no longer creates an empty cache that bypasses onboarding next launch.
- Network mount availability no longer invalidates the cached index at launch.
- Outdated network scans cannot reintroduce files excluded by changed settings, and local live indexing does not traverse network trees.
- Selection and open context menus retain their file paths across live refreshes; rebuilt record IDs cannot redirect file actions to another result.
- Superseded rebuilds stop their workers and discard late progress; canceled or failed root scans preserve the last searchable snapshot and safe event checkpoint.
- Incomplete network refreshes preserve known files, complete refreshes replace stale local mount-point entries, and unchanged-rule rebuilds retain offline share entries. Each Connect button mounts only its selected share.
- Live indexing preserves children after access failures, retries incomplete subtrees, handles file/directory replacements, and rejects replaced symlink ancestors.
- Folder exclusions respect path-component boundaries; directory scope lookups reject similarly named outside paths and file nodes.
- Directory lookup and live diffs preserve exact UTF-8 names, including distinct Unicode spellings. Scanned and grafted root sizes and modification dates come from filesystem metadata.
- Cache loading rejects nonregular files without waiting on FIFO writers.
- Unicode wildcard matching, literal query narrowing, fuzzy path typos, canceled whole-word searches, and tied result ordering now retain complete, consistent results.
- TSV exports quote filename delimiters, and unavailable cache modification dates are omitted.

## [0.3.0] - 2026-06-24

### Added
- Menu bar commands. The File, Edit, View, and Help menus now drive search focus (⌘F), sorting, and index rebuild, and a new File ▸ Export writes the current results to a tab-separated file.
- Reworked Settings, split into General, Search, Exclude, and Volumes tabs — with live search preferences, index stats, launch-at-login, a rebuild button, and per-volume and per-folder exclusion controls.
- Match Case and Match Whole Word search options, plus a configurable result limit (it was a fixed 5,000 rows). These, along with the sort order, now persist across launches.
- Exclude the Trash by default (with a toggle), custom excluded folder names, and excluded file patterns such as `*.tmp` or `Thumbs.db`.

### Fixed
- New files in your home folder — Desktop, Documents, Downloads, and the rest — now appear instantly instead of lagging minutes behind. The app watches the macOS Data volume directly, and sweeps the iCloud-backed Desktop/Documents/Downloads folders that don't emit timely filesystem events.
- The window no longer locks up after a minute or so of use. A coalesced "rescan everything under here" filesystem event used to trigger a synchronous walk of the entire disk on the same thread as search, pegging a CPU core and freezing the UI. Deep rescans are now incremental and yield to your searches, and a whole-volume overflow no longer re-walks the whole disk.
- The same folder no longer appears twice — once under `/Users/…` and again under `/System/Volumes/Data/…`. Live indexing was missing an exclusion and could index the Data volume's internal firmlink alias as a duplicate. That's fixed, and any index already carrying these duplicates is detected and rebuilt clean automatically on the next launch.

## [0.2.2] - 2026-06-23

### Fixed
- High CPU during normal use. The live-update watcher re-read a whole directory on every filesystem event, and its per-entry "is this new?" check was a linear scan — so the diff was quadratic, and a big busy folder (like a browser cache) pegged a CPU core. The diff is now linear, and directories whose entries didn't change are skipped entirely (a directory-mtime check), so idle CPU drops to near zero while new, renamed, and deleted files are still picked up.

## [0.2.1] - 2026-06-23

### Fixed
- Indexing no longer hangs when a network share is mounted. The scan used to descend into SMB/NFS shares under `/Volumes` and stall on slow network reads (one mounted share with millions of files froze it indefinitely). Network volumes are now skipped — local volumes only.

## [0.2.0] - 2026-06-23

### Added
- Skip developer folders by default. `node_modules`, `Pods`, `DerivedData`, `.gradle`, `.cargo`, `__pycache__`, `.venv` and similar are left out of the index. Generic names like `build`, `dist`, and `target` are skipped only inside an actual project (a folder that also holds a `Cargo.toml`, `package.json`, `.git`, etc.), so a personal folder you happen to name "build" still shows up in search. Toggle in Settings.
- Skip version-control folders (`.git`, `.hg`, `.svn`) by default, on a separate toggle.

### Fixed
- Runaway CPU that climbed the longer the app stayed open. It no longer re-searches the whole index on every background file change — only when something it indexes actually changes.
- Live updates are more reliable: new files and bulk changes (a `git clone`, an `npm install`) are picked up without thrashing, and deep coalesced filesystem events are no longer missed.
- The on-disk index cache is rebuilt when the exclusion rules that shaped it change, instead of serving a stale index.
- The app now reports its real version (it was hardcoded to `1.0`).

## [0.1.0] - 2026-06-05

### Added
- First public release. Instant filename and folder search across every mounted volume, updating as you type. FSEvents-backed live index, a binary on-disk cache for instant restarts, and right-click actions (Open, Open With, Reveal in Finder, Copy Path/Name, Move to Trash).

[0.5.0]: https://github.com/alesloa/everything-mac/compare/v0.3.0...main
[0.4.0]: https://github.com/alesloa/everything-mac/compare/v0.3.0...main
[0.3.0]: https://github.com/alesloa/everything-mac/releases/tag/v0.3.0
[0.2.2]: https://github.com/alesloa/everything-mac/releases/tag/v0.2.2
[0.2.1]: https://github.com/alesloa/everything-mac/releases/tag/v0.2.1
[0.2.0]: https://github.com/alesloa/everything-mac/releases/tag/v0.2.0
[0.1.0]: https://github.com/alesloa/everything-mac/releases/tag/v0.1.0
