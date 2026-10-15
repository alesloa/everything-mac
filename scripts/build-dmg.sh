#!/usr/bin/env bash
# Build a universal Release app and MCP helper, sign, and package a versioned DMG.
# Default: Developer ID + notarization (DEVELOPER_ID and the "notary" profile).
# --development-signed: use App/project.yml's Apple Development identity, with
# no notarization, matching the existing public GitHub releases.
set -euo pipefail

RELEASE_PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$RELEASE_PROJECT_ROOT"
RELEASE_WORK="$RELEASE_PROJECT_ROOT/.build/production"
RELEASE_MODE="${1:---notarize}"
case "$RELEASE_MODE" in
  --notarize) : "${DEVELOPER_ID:?set DEVELOPER_ID to your Developer ID Application identity}" ;;
  --development-signed) ;;
  *) printf 'Unknown release mode: %s\n' "$RELEASE_MODE" >&2; exit 2 ;;
esac

# Separate native SwiftPM builds preserve macOS 14 deployment for both slices.
RELEASE_MCP_INPUTS=()
for RELEASE_ARCH in arm64 x86_64; do
    swift build --scratch-path "$RELEASE_WORK/SwiftPM" \
      --triple "$RELEASE_ARCH-apple-macosx14.0" -c release \
      --force-resolved-versions --product everything-mcp
    RELEASE_BIN_DIR="$(swift build --scratch-path "$RELEASE_WORK/SwiftPM" \
      --triple "$RELEASE_ARCH-apple-macosx14.0" -c release --show-bin-path)"
    RELEASE_MCP_INPUTS+=("$RELEASE_BIN_DIR/everything-mcp")
done

cd App
xcodegen generate
xcodebuild -project EverythingMac.xcodeproj -scheme EverythingMac \
  -configuration Release -derivedDataPath "$RELEASE_WORK/DerivedData" \
  -destination 'generic/platform=macOS' ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO clean build

RELEASE_APP="$RELEASE_WORK/DerivedData/Build/Products/Release/EverythingMac.app"
RELEASE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$RELEASE_APP/Contents/Info.plist")"
lipo -create "${RELEASE_MCP_INPUTS[@]}" -output "$RELEASE_APP/Contents/MacOS/everything-mcp"
chmod 755 "$RELEASE_APP/Contents/MacOS/everything-mcp"
python3 ../scripts/bundle-mcp-licenses.py "$RELEASE_WORK/SwiftPM/checkouts" \
  "$RELEASE_APP/Contents/Resources/MCP-Licenses"

for RELEASE_EXECUTABLE in EverythingMac everything-mcp; do
    lipo "$RELEASE_APP/Contents/MacOS/$RELEASE_EXECUTABLE" -verify_arch arm64 x86_64
done
RELEASE_MCP_VERSION="$("$RELEASE_APP/Contents/MacOS/everything-mcp" --version)"
if [[ "$RELEASE_MCP_VERSION" != "$RELEASE_VERSION" ]]; then
    printf 'App version %s does not match MCP version %s\n' "$RELEASE_VERSION" "$RELEASE_MCP_VERSION" >&2
    exit 1
fi

if [[ "$RELEASE_MODE" == --development-signed ]]; then
    RELEASE_BUILD_SETTINGS="$(xcodebuild -project EverythingMac.xcodeproj -scheme EverythingMac \
      -configuration Release -showBuildSettings 2>/dev/null)"
    RELEASE_SIGNING_IDENTITY="$(awk -F' = ' '/ CODE_SIGN_IDENTITY /{print $2; exit}' <<< "$RELEASE_BUILD_SETTINGS")"
    : "${RELEASE_SIGNING_IDENTITY:?missing CODE_SIGN_IDENTITY in Xcode build settings}"
    RELEASE_SIGNING_FLAGS=(--force --sign "$RELEASE_SIGNING_IDENTITY" --timestamp=none)
else
    RELEASE_SIGNING_FLAGS=(--force --sign "$DEVELOPER_ID" --options runtime --timestamp)
fi

# Nested code is signed before the outer app; do not use --deep for signing.
codesign "${RELEASE_SIGNING_FLAGS[@]}" "$RELEASE_APP/Contents/MacOS/everything-mcp"
codesign "${RELEASE_SIGNING_FLAGS[@]}" --entitlements EverythingMac.entitlements "$RELEASE_APP"
codesign --verify --deep --strict "$RELEASE_APP"

RELEASE_OUTPUT="$RELEASE_PROJECT_ROOT/.build/releases/$RELEASE_VERSION"
mkdir -p "$RELEASE_OUTPUT"
RELEASE_STAGE="$(mktemp -d "$RELEASE_WORK/dmg-stage.XXXXXX")"
trap 'rm -rf "$RELEASE_STAGE"' EXIT
ditto "$RELEASE_APP" "$RELEASE_STAGE/EverythingMac.app"
ln -s /Applications "$RELEASE_STAGE/Applications"
RELEASE_DMG="$RELEASE_OUTPUT/EverythingMac-$RELEASE_VERSION.dmg"
hdiutil create -volname "EverythingMac $RELEASE_VERSION" -srcfolder "$RELEASE_STAGE" \
  -ov -format UDZO "$RELEASE_DMG"

if [[ "$RELEASE_MODE" == --notarize ]]; then
    xcrun notarytool submit "$RELEASE_DMG" --keychain-profile notary --wait
    xcrun stapler staple "$RELEASE_DMG"
    xcrun stapler validate "$RELEASE_DMG"
    spctl --assess --type execute "$RELEASE_APP"
fi
cd "$RELEASE_OUTPUT"
shasum -a 256 "$(basename "$RELEASE_DMG")" > "$(basename "$RELEASE_DMG").sha256"
printf 'Built: %s\nSigning mode: %s\n' "$RELEASE_DMG" "$RELEASE_MODE"
