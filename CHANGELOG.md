# Changelog

All notable changes to EverythingMac are recorded here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) (`MAJOR.MINOR.PATCH`).

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

[0.2.2]: https://github.com/alesloa/everything-mac/releases/tag/v0.2.2
[0.2.1]: https://github.com/alesloa/everything-mac/releases/tag/v0.2.1
[0.2.0]: https://github.com/alesloa/everything-mac/releases/tag/v0.2.0
[0.1.0]: https://github.com/alesloa/everything-mac/releases/tag/v0.1.0
