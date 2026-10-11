#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/everything-global-access.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
app_inputs=()
while IFS= read -r app_input; do
    [[ "$app_input" == "App/Sources/EverythingMacApp.swift" ]] || app_inputs+=("$app_input")
done < <(rg --files App/Sources -g '*.swift' | sort)
swiftc -O -swift-version 6 -parse-as-library -I .build/release/Modules \
    "${app_inputs[@]}" Tests/AppIntegrationTests/GlobalAccess.swift \
    .build/release/IndexCore.build/*.o \
    -framework CoreServices -framework NetFS -framework AppKit -framework SwiftUI -framework Carbon \
    -framework QuickLookUI -framework QuickLookThumbnailing -framework ImageIO \
    -o "$test_dir/global-access"
"$test_dir/global-access"
