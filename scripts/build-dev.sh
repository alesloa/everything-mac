#!/usr/bin/env bash
#
# Build a local Release build of Everything-Mac, signed with a stable Apple
# Development identity so Full Disk Access persists across rebuilds.
#
# Why Release (not Debug): the search match-loop is ~100x slower unoptimized
# (~1.5s vs ~14ms per million records). A Debug build feels broken on a
# whole-disk index. Always test with this script, not Xcode's default Debug run.
#
# Signing identity + team come from App/project.yml (CODE_SIGN_IDENTITY /
# DEVELOPMENT_TEAM). Empty entitlements + non-sandboxed → no provisioning
# profile needed for local use.
#
# Usage: ./scripts/build-dev.sh   →   prints the built .app path.
set -euo pipefail

cd "$(dirname "$0")/../App"

xcodegen generate
xcodebuild -project EverythingMac.xcodeproj -scheme EverythingMac \
  -configuration Release clean build

# Resolve the real product path from build settings (honors a custom global
# DerivedData location if one is set).
APP="$(xcodebuild -project EverythingMac.xcodeproj -scheme EverythingMac \
        -configuration Release -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/EverythingMac.app"

# Deploy to /Applications so Full Disk Access is granted against one stable path.
# The designated requirement is identical across rebuilds (same bundle id + cert),
# so replacing the bundle here keeps the existing FDA grant — no re-granting.
ditto "$APP" "/Applications/EverythingMac.app"

echo
echo "Built + deployed: /Applications/EverythingMac.app"
echo "Signature:"
codesign -dv "/Applications/EverythingMac.app" 2>&1 \
  | grep -iE "Identifier=|Authority=|TeamIdentifier=|flags=" | sed 's/^/  /'
echo "Run ./scripts/relaunch.sh to restart with a fresh scan."
