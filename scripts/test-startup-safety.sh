#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
startup_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/everything-startup-safety.XXXXXX")"
trap 'rm -rf "$startup_test_dir"' EXIT
# Exercise real FSEvents callbacks with ASan in an isolated build directory.
swift test -c release --sanitize address --scratch-path "$startup_test_dir/build" \
    --filter 'Startup|concurrentMount'
swiftc -O -g -sanitize=address -swift-version 6 -parse-as-library \
    -I "$startup_test_dir/build/release/Modules" \
    App/Sources/ResultsTable.swift App/Sources/FileIcons.swift App/Sources/ResultActions.swift \
    Tests/AppIntegrationTests/TableSafety.swift "$startup_test_dir/build/release/IndexCore.build/"*.o \
    -framework AppKit -framework SwiftUI -framework CoreServices -o "$startup_test_dir/table-safety"
"$startup_test_dir/table-safety"
