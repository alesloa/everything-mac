#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/everything-global-access.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -O -swift-version 6 -parse-as-library -I .build/release/Modules \
    App/Sources/IndexActor.swift App/Sources/IndexScanCancellation.swift \
    App/Sources/ShareIndexMutation.swift App/Sources/NetworkMounter.swift \
    App/Sources/AppModel.swift App/Sources/FullDiskAccess.swift \
    App/Sources/AppDelegate.swift App/Sources/GlobalAccessPreferences.swift \
    App/Sources/CarbonGlobalHotKey.swift App/Sources/GlobalAccessSettingsView.swift \
    App/Sources/GlobalAccessController.swift Tests/AppIntegrationTests/GlobalAccess.swift \
    .build/release/IndexCore.build/*.o \
    -framework CoreServices -framework NetFS -framework AppKit -framework SwiftUI -framework Carbon \
    -o "$test_dir/global-access"
"$test_dir/global-access"
