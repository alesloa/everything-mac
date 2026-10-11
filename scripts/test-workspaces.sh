#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
workspace_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/everything-workspaces.XXXXXX")"
trap 'rm -rf "$workspace_test_dir"' EXIT
swiftc -O -swift-version 6 -parse-as-library -I .build/release/Modules \
    App/Sources/WorkspaceLibrary.swift App/Sources/SearchWorkspaceController.swift \
    Tests/AppIntegrationTests/WorkspacePersistence.swift .build/release/IndexCore.build/*.o \
    -o "$workspace_test_dir/workspaces"
"$workspace_test_dir/workspaces"
