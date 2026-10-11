#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
quick_look_dir="$(mktemp -d "${TMPDIR:-/tmp}/everything-quick-look.XXXXXX")"
trap 'rm -rf "$quick_look_dir"' EXIT
swiftc -O -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
    -I .build/release/Modules \
    App/Sources/PreviewFileAccess.swift App/Sources/PreviewPane.swift \
    App/Sources/QuickLookController.swift App/Sources/ThumbnailService.swift \
    App/Sources/ThumbnailResultsView.swift App/Sources/ResultsGridLayout.swift App/Sources/ResultsTable.swift App/Sources/ResultsTableVirtualRows.swift App/Sources/ResultSelectionAction.swift \
    App/Sources/ResultsColumnLayout.swift App/Sources/ResultsTableColumns.swift App/Sources/ResultsTableHighlights.swift \
    App/Sources/SelectionIdentity.swift App/Sources/ResultActions.swift App/Sources/FileIcons.swift \
    App/Sources/FileOperations.swift App/Sources/FileActionState.swift \
    App/Sources/BatchRename.swift App/Sources/FinderInfoRequest.swift \
    Tests/AppIntegrationTests/QuickLook.swift .build/release/IndexCore.build/*.o \
    -framework AppKit -framework SwiftUI -framework QuickLookUI \
    -framework QuickLookThumbnailing -framework ImageIO -o "$quick_look_dir/EverythingPreviewTests"
preview_checks="$quick_look_dir/EverythingPreviewTests"
if "$preview_checks" --verify-failure-exit > "$quick_look_dir/assertion-exit.log" 2>&1; then
    echo "FAIL: preview assertion unexpectedly succeeded"
    exit 1
else
    failure_status=$?
fi
if [[ "$failure_status" != 1 ]]; then
    cat "$quick_look_dir/assertion-exit.log"
    echo "FAIL: preview assertion did not exit normally with status 1"
    exit 1
fi
grep -qF 'FAIL: Intentional preview assertion failure' "$quick_look_dir/assertion-exit.log"
echo "PASS: preview assertion failures exit normally with status 1"
"$preview_checks"
