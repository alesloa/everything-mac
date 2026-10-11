#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
result_details_dir="$(mktemp -d "${TMPDIR:-/tmp}/everything-result-details.XXXXXX")"
trap 'rm -rf "$result_details_dir"' EXIT
swiftc -O -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
    -I .build/release/Modules \
    App/Sources/ResultsTable.swift App/Sources/ResultsColumnLayout.swift \
    App/Sources/ResultsTableColumns.swift App/Sources/ResultsTableHighlights.swift \
    App/Sources/FolderDetailsModel.swift App/Sources/FolderSidebarView.swift \
    App/Sources/SelectionIdentity.swift App/Sources/ResultActions.swift App/Sources/FileIcons.swift \
    App/Sources/FileOperations.swift App/Sources/FileActionState.swift \
    App/Sources/BatchRename.swift App/Sources/FinderInfoRequest.swift \
    Tests/AppIntegrationTests/ResultDetails.swift .build/release/IndexCore.build/*.o \
    -framework AppKit -framework SwiftUI -o "$result_details_dir/ResultDetails"
"$result_details_dir/ResultDetails"
