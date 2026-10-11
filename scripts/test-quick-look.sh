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
    App/Sources/ThumbnailResultsView.swift App/Sources/ResultsTable.swift \
    App/Sources/SelectionIdentity.swift App/Sources/ResultActions.swift App/Sources/FileIcons.swift \
    App/Sources/FileOperations.swift App/Sources/FileActionState.swift \
    App/Sources/BatchRename.swift App/Sources/FinderInfoRequest.swift \
    Tests/AppIntegrationTests/QuickLook.swift .build/release/IndexCore.build/*.o \
    -framework AppKit -framework SwiftUI -framework QuickLookUI \
    -framework QuickLookThumbnailing -framework ImageIO -o "$quick_look_dir/QuickLook"
"$quick_look_dir/QuickLook"
