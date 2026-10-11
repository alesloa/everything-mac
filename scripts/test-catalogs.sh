#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --filter CatalogTests
swift build -c release
catalog_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/everything-catalog-test.XXXXXX")"
trap 'rm -rf "$catalog_test_dir"' EXIT
swiftc -O -swift-version 6 -parse-as-library -I .build/release/Modules \
    App/Sources/CatalogStore.swift App/Sources/CatalogBrowserView.swift App/Sources/NativeResultsExportView.swift \
    Tests/AppIntegrationTests/CatalogAppSafety.swift .build/release/IndexCore.build/*.o \
    -framework CoreServices -framework AppKit -framework SwiftUI -o "$catalog_test_dir/catalogs"
"$catalog_test_dir/catalogs"
