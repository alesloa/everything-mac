#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
network_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/everything-network-refresh.XXXXXX")"
trap 'rm -rf "$network_test_dir"' EXIT
swiftc -O -swift-version 6 -parse-as-library -I .build/release/Modules \
    App/Sources/IndexActor.swift App/Sources/IndexScanCancellation.swift \
    App/Sources/ShareIndexMutation.swift App/Sources/NetworkMounter.swift \
    Tests/AppIntegrationTests/NetworkRefresh.swift .build/release/IndexCore.build/*.o \
    -framework CoreServices -framework NetFS -o "$network_test_dir/network-refresh"
"$network_test_dir/network-refresh"
