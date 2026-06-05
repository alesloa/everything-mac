# EverythingMac

Instant filename search for macOS. Start typing and every matching file and folder on every mounted volume shows up as you press each key — the way [Everything](https://www.voidtools.com/) works on Windows.

> The folder is named `everything-rust` for historical reasons. The app is written entirely in **Swift / SwiftUI / AppKit**.

## Why I made this

I came to Mac from Windows. On Windows I lived in **Everything** by voidtools — hit a shortcut, type part of a name, and it instantly lists every file and folder that matches across the whole disk. No spinner, no guessing, no "did it index yet."

macOS Spotlight is supposed to do this. It doesn't, not well. When I search for a **folder** it often won't show all the folders that actually match — it hides things, ranks them strangely, and makes me dig. I'm a programmer. I don't have time to fight my own search tool. Finding a file or a folder is the most basic thing a computer should do, and it should *just always work*.

So I built this: a small, fast, native app that indexes every filename on the machine and searches it instantly. Open it, type, find it, done. Need to open something? Right-click and open it with whatever app you want.

## What it does

- **Instant search** across all mounted volumes — results update on every keystroke.
- Indexes the **whole disk** (files *and* folders), kept live with the filesystem via FSEvents.
- Classic results table: **Name · Path · Size · Kind · Date Modified** — click any column to sort.
- **File-type icons** and human-readable kinds.
- **Right-click menu:** Open · Open With ▸ (every associated app, plus a *Choose Application…* picker so you can open anything with any app) · Reveal in Finder · Copy Path · Copy Name · Move to Trash.
- Stays fast on millions of files — custom flat index, parallel substring scan, bounded top-K sort.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16 or later (Swift 6 toolchain)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build & run

```bash
git clone https://github.com/alesloa/everything-mac.git
cd everything-mac
./scripts/build-dev.sh
```

`build-dev.sh` generates the Xcode project from `App/project.yml`, builds a **Release** binary (the search loop is ~100× slower unoptimized — always build Release), and copies the app to `/Applications/EverythingMac.app`.

### Code signing (for your own build)

`App/project.yml` ships with *my* Apple Development identity so Full Disk Access survives rebuilds on my machine. To build on yours, do one of:

- Open `App/EverythingMac.xcodeproj` in Xcode → select the **EverythingMac** target → **Signing & Capabilities** → enable *Automatically manage signing* and choose your own Team; or
- Edit `CODE_SIGN_IDENTITY` and `DEVELOPMENT_TEAM` in `App/project.yml` to your own values, then re-run `./scripts/build-dev.sh`.

### Grant Full Disk Access

To index everything, the app needs Full Disk Access:

**System Settings → Privacy & Security → Full Disk Access** → enable **EverythingMac**.

On first launch it scans the whole disk (a few minutes, depending on how many files you have) and caches the index, so later launches start instantly. Filesystem changes are picked up live.

## Usage

- Launch EverythingMac and start typing — matches appear immediately.
- Click a column header to sort by Name / Path / Size / Kind / Date Modified.
- Double-click a row to open it. Right-click for **Open With**, Reveal in Finder, Copy Path, Move to Trash, and more.

## How it works (short version)

- A flat **struct-of-arrays index** holds every filename in one contiguous UTF-8 arena with parallel metadata arrays, serialized to a binary cache for fast restarts.
- Search is a **parallel substring scan** across all cores feeding a **bounded max-heap** for the top results, so typing stays instant even with millions of records.
- A live **FSEvents** monitor reconciles new / renamed / deleted files into the index without a full rescan.

## License

[MIT](LICENSE)
