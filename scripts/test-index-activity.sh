#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
activity_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/everything-index-activity.XXXXXX")"
trap 'rm -rf "$activity_test_dir"' EXIT
swiftc -O -swift-version 6 -parse-as-library -I .build/release/Modules \
    App/Sources/IndexActor.swift App/Sources/IndexScanCancellation.swift \
    App/Sources/ShareIndexMutation.swift App/Sources/NetworkMounter.swift \
    Tests/AppIntegrationTests/IndexActivity.swift .build/release/IndexCore.build/*.o \
    -framework CoreServices -framework NetFS -o "$activity_test_dir/index-activity"
"$activity_test_dir/index-activity"
