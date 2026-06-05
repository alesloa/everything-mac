#!/usr/bin/env bash
#
# Quit the app, drop the index cache, and relaunch — forcing a fresh whole-disk
# scan. Run this AFTER granting Full Disk Access so the first scan can see every
# volume (without FDA, macOS hides the Data volume's firmlinks from the scan and
# you only get System-volume files).
set -euo pipefail

pkill -x EverythingMac 2>/dev/null || true
sleep 1

CACHE="$HOME/Library/Application Support/Everything-Mac/index.idx"
: > "$CACHE" 2>/dev/null || true   # truncate (not rm) → load fails → full rescan

open "/Applications/EverythingMac.app"
echo "Launched /Applications/EverythingMac.app"
echo "First whole-disk scan takes ~2-3 min; the status bar shows 'Indexing… N files'."
