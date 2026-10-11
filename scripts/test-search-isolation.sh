#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/everything-search-isolation.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -O -swift-version 6 -parse-as-library -I .build/release/Modules \
    App/Sources/IndexActor.swift App/Sources/NetworkMounter.swift \
    Tests/AppIntegrationTests/SearchIsolation.swift .build/release/IndexCore.build/*.o \
    -framework CoreServices -framework NetFS -o "$test_dir/search-isolation"
"$test_dir/search-isolation"
