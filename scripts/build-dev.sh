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

cd "$(dirname "$0")/.."

# The app includes the same read-only MCP executable as the standalone package.
swift build -c release --product everything-mcp
MCP_EXECUTABLE="$PWD/.build/release/everything-mcp"

cd App

xcodegen generate
xcodebuild -project EverythingMac.xcodeproj -scheme EverythingMac \
  -configuration Release clean build

# Resolve the real product path from build settings (honors a custom global
# DerivedData location if one is set).
BUILD_SETTINGS="$(xcodebuild -project EverythingMac.xcodeproj -scheme EverythingMac \
        -configuration Release -showBuildSettings 2>/dev/null)"
APP="$(awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}' <<< "$BUILD_SETTINGS")/EverythingMac.app"
SIGNING_IDENTITY="$(awk -F' = ' '/ EXPANDED_CODE_SIGN_IDENTITY /{print $2; exit}' <<< "$BUILD_SETTINGS")"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(awk -F' = ' '/ CODE_SIGN_IDENTITY /{print $2; exit}' <<< "$BUILD_SETTINGS")"
fi

# Source: this build's product and signing settings. Stop before deployment if
# either is missing, rather than replacing the installed app with a partial one.
if [[ ! -d "$APP" || -z "$SIGNING_IDENTITY" ]]; then
    printf 'Missing app product or signing identity in Xcode build settings.\n' >&2
    exit 1
fi

# Sign the nested executable first, then seal the modified outer bundle while
# retaining Xcode's identifier, entitlements, designated requirement and flags.
install -m 755 "$MCP_EXECUTABLE" "$APP/Contents/MacOS/everything-mcp"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP/Contents/MacOS/everything-mcp"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none \
  --preserve-metadata=identifier,entitlements,requirements,flags "$APP"
codesign --verify --deep --strict "$APP"

# Deploy to /Applications so Full Disk Access is granted against one stable path.
# The designated requirement is identical across rebuilds (same bundle id + cert),
# so replacing the bundle here keeps the existing FDA grant — no re-granting.
ditto "$APP" "/Applications/EverythingMac.app"
codesign --verify --deep --strict "/Applications/EverythingMac.app"

echo
echo "Built + deployed: /Applications/EverythingMac.app"
echo "Signature:"
codesign -dv "/Applications/EverythingMac.app" 2>&1 \
  | grep -iE "Identifier=|Authority=|TeamIdentifier=|flags=" | sed 's/^/  /'
echo "MCP command: /Applications/EverythingMac.app/Contents/MacOS/everything-mcp"
echo "Run open /Applications/EverythingMac.app to launch with the saved index."
