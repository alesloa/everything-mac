# EverythingMac

Type part of a filename and every file and folder that matches shows up instantly, across every mounted volume. It's a macOS clone of [Everything](https://www.voidtools.com/), the search tool I lived in back on Windows.

> The folder is called `everything-rust` for historical reasons. There's no Rust in it. The whole app is Swift (SwiftUI and AppKit).

## Why I built it

I switched to Mac from Windows, and the one tool I missed right away was Everything by voidtools. Hit a shortcut, type a few letters, and it lists every matching file and folder on the whole disk before you finish typing. It doesn't make you wait while it builds an index, and it doesn't reshuffle the results to show you what it thinks you meant.

Spotlight is supposed to cover this. It doesn't, at least not for me. The part that broke it was folder search: I'd look for a folder I knew was there and Spotlight wouldn't list all the ones that matched. It buries results and second-guesses what I actually typed. I'm a programmer. Finding a file by name is the most basic thing a computer does, and I don't want to fight it to do that.

So I wrote my own. It reads every filename on the machine into memory and searches that as you type. Open it, type, it's there. Want to open the file? Right-click and pick whatever app you want.

## What it does

- Searches every mounted volume, updating on each keystroke.
- Indexes the whole disk, files and folders, and keeps the index current through FSEvents.
- Standard results table with Name, Path, Size, Kind, and Date Modified. Click a header to sort.
- Shows the real file-type icon and a readable kind for each row.
- Right-click menu: Open, Open With (lists every app associated with the file, plus a "Choose Application…" option to open it with anything), Reveal in Finder, Copy Path, Copy Name, Move to Trash.
- Handles millions of files without choking. The index is a flat array scanned in parallel across all cores.

## Requirements

- macOS 14 (Sonoma) or newer
- Xcode 16 or newer (Swift 6)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build and run

```bash
git clone https://github.com/alesloa/everything-mac.git
cd everything-mac
./scripts/build-dev.sh
```

The script generates the Xcode project from `App/project.yml`, builds a Release binary, and copies the app into `/Applications`. Build Release, not Debug. The search loop runs about 100x slower without optimization.

### Signing it as yourself

`App/project.yml` has my Apple Development identity hardcoded so Full Disk Access doesn't get revoked every time I rebuild on my own machine. To build it on yours, do one of these:

- Open `App/EverythingMac.xcodeproj` in Xcode, select the EverythingMac target, go to Signing & Capabilities, turn on "Automatically manage signing," and pick your team.
- Or edit `CODE_SIGN_IDENTITY` and `DEVELOPMENT_TEAM` in `App/project.yml` to your own values and re-run `./scripts/build-dev.sh`.

### Full Disk Access

The app can only index everything if you give it Full Disk Access:

System Settings > Privacy & Security > Full Disk Access > turn on EverythingMac.

The first launch scans the whole disk and writes the index to a cache, so it takes a few minutes depending on how many files you have. After that it starts instantly and picks up file changes as they happen.

## Using it

Launch it and start typing. Matches show up right away. Click a column header to sort. Double-click a row to open it, or right-click for Open With, Reveal in Finder, Copy Path, Move to Trash, and the rest.

## How it works

- Every filename lives in one big UTF-8 buffer, with the metadata (size, dates, flags) held in parallel arrays alongside it. That whole structure gets written to a binary cache so restarts are fast.
- A search runs as a parallel substring scan across all CPU cores, feeding a fixed-size max-heap that keeps only the top results. That's what keeps typing responsive even with millions of records.
- An FSEvents watcher folds new, renamed, and deleted files back into the index so it never needs a full rescan.

## License

[MIT](LICENSE)
