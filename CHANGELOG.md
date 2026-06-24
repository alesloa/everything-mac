# Changelog

All notable changes to EverythingMac are recorded here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) (`MAJOR.MINOR.PATCH`).

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

[0.3.0]: https://github.com/alesloa/everything-mac/releases/tag/v0.3.0
[0.2.2]: https://github.com/alesloa/everything-mac/releases/tag/v0.2.2
[0.2.1]: https://github.com/alesloa/everything-mac/releases/tag/v0.2.1
[0.2.0]: https://github.com/alesloa/everything-mac/releases/tag/v0.2.0
[0.1.0]: https://github.com/alesloa/everything-mac/releases/tag/v0.1.0
