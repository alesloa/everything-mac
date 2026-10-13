#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
app_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/everything-app-safety.XXXXXX")"
trap 'rm -rf "$app_test_dir"' EXIT
app_test_inputs=()
while IFS= read -r app_test_input; do
    if [[ "$app_test_input" != "App/Sources/EverythingMacApp.swift" ]]; then
        app_test_inputs+=("$app_test_input")
    fi
done < <(rg --files App/Sources -g '*.swift' | sort)
app_test_sources=(Tests/AppIntegrationTests/AppSafety.swift
    Tests/AppIntegrationTests/ScanLifecycle.swift Tests/AppIntegrationTests/TableSafety.swift
    Tests/AppIntegrationTests/WindowIsolation.swift Tests/AppIntegrationTests/SidebarLayout.swift
    Tests/AppIntegrationTests/FolderMultiselect.swift)
if [[ "$#" -gt 0 ]]; then app_test_sources=("$@"); fi
for app_test_source in "${app_test_sources[@]}"; do
    app_test_binary="$app_test_dir/$(basename "$app_test_source" .swift)"
    swiftc -O -swift-version 6 -parse-as-library -I .build/release/Modules \
        "${app_test_inputs[@]}" "$app_test_source" .build/release/IndexCore.build/*.o \
        -framework CoreServices -framework NetFS -framework AppKit -framework SwiftUI \
        -framework QuickLookUI -framework QuickLookThumbnailing -framework ImageIO -framework Carbon \
        -o "$app_test_binary"
    "$app_test_binary"
done
