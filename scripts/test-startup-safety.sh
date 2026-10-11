#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
startup_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/everything-startup-safety.XXXXXX")"
trap 'rm -rf "$startup_test_dir"' EXIT
# Exercise the engine regressions and real FSEvents callbacks with ASan.
swift test -c release --sanitize address --scratch-path "$startup_test_dir/build"
swiftc -O -g -sanitize=address -swift-version 6 -parse-as-library \
    -I "$startup_test_dir/build/release/Modules" \
    App/Sources/ResultsTable.swift App/Sources/ResultsTableVirtualRows.swift App/Sources/ResultSelectionAction.swift App/Sources/FileIcons.swift App/Sources/ResultActions.swift \
    App/Sources/ResultsColumnLayout.swift App/Sources/ResultsTableColumns.swift App/Sources/ResultsTableHighlights.swift \
    App/Sources/SelectionIdentity.swift App/Sources/FileOperations.swift App/Sources/FileActionState.swift \
    App/Sources/BatchRename.swift App/Sources/FinderInfoRequest.swift \
    Tests/AppIntegrationTests/TableSafety.swift "$startup_test_dir/build/release/IndexCore.build/"*.o \
    -framework AppKit -framework SwiftUI -framework CoreServices -o "$startup_test_dir/table-safety"
"$startup_test_dir/table-safety"
