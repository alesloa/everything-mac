#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
file_actions_dir="$(mktemp -d "${TMPDIR:-/tmp}/everything-file-actions.XXXXXX")"
trap 'rm -rf "$file_actions_dir"' EXIT
swiftc -O -swift-version 6 -parse-as-library -I .build/release/Modules \
    App/Sources/ResultsTable.swift App/Sources/ResultActions.swift App/Sources/FileIcons.swift \
    App/Sources/ResultsColumnLayout.swift App/Sources/ResultsTableColumns.swift App/Sources/ResultsTableHighlights.swift \
    App/Sources/FileOperations.swift App/Sources/FileActionState.swift \
    App/Sources/BatchRename.swift App/Sources/SelectionIdentity.swift App/Sources/FinderInfoRequest.swift \
    Tests/AppIntegrationTests/FileActions.swift .build/release/IndexCore.build/*.o \
    -framework AppKit -framework SwiftUI -o "$file_actions_dir/FileActions"
"$file_actions_dir/FileActions"
