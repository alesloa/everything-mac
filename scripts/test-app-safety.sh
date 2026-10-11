#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
app_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/everything-app-safety.XXXXXX")"
trap 'rm -rf "$app_test_dir"' EXIT
app_test_inputs=(
    App/Sources/IndexActor.swift App/Sources/IndexScanCancellation.swift
    App/Sources/ShareIndexMutation.swift App/Sources/NetworkMounter.swift
    App/Sources/AppModel.swift App/Sources/FullDiskAccess.swift
    App/Sources/ResultsTable.swift App/Sources/FileIcons.swift App/Sources/ResultActions.swift
)
for app_test_source in Tests/AppIntegrationTests/AppSafety.swift \
    Tests/AppIntegrationTests/ScanLifecycle.swift Tests/AppIntegrationTests/TableSafety.swift; do
    app_test_binary="$app_test_dir/$(basename "$app_test_source" .swift)"
    swiftc -O -swift-version 6 -parse-as-library -I .build/release/Modules \
        "${app_test_inputs[@]}" "$app_test_source" .build/release/IndexCore.build/*.o \
        -framework CoreServices -framework NetFS -framework AppKit -framework SwiftUI \
        -o "$app_test_binary"
    "$app_test_binary"
done
