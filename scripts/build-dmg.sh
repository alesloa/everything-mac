#!/usr/bin/env bash
#
# Build, sign, notarize, and package Everything-Mac as a distributable DMG.
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in your login keychain.
#      Export its identity name and pass it via the DEVELOPER_ID env var, e.g.
#        export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   2. A stored notarytool credential profile named "notary":
#        xcrun notarytool store-credentials notary \
#          --apple-id you@example.com --team-id TEAMID --password <app-specific-pw>
#
# Usage:
#   DEVELOPER_ID="Developer ID Application: ..." ./scripts/build-dmg.sh
#
set -euo pipefail

cd "$(dirname "$0")/../App"

# Regenerate the Xcode project (it is gitignored) and build a clean Release.
xcodegen generate
xcodebuild -project EverythingMac.xcodeproj -scheme EverythingMac -configuration Release \
  -derivedDataPath build clean build

APP="build/Build/Products/Release/EverythingMac.app"

# Re-sign with Developer ID + hardened runtime. Notarization requires both a
# secure timestamp (--timestamp) and the hardened runtime (--options runtime).
# --entitlements preserves the non-sandbox entitlement that whole-disk indexing
# needs (a bare re-sign would drop it). --deep is deprecated by Apple but still
# signs the bundled Swift runtime dylibs for this single-target app.
codesign --force --deep --options runtime --timestamp \
  --entitlements EverythingMac.entitlements \
  --sign "${DEVELOPER_ID:?set DEVELOPER_ID to your Developer ID Application identity}" \
  "$APP"

# Verify the signature is valid and accepted by Gatekeeper before packaging.
codesign --verify --strict --verbose=2 "$APP"

# Package into a compressed DMG.
DMG="EverythingMac.dmg"
rm -f "$DMG"
hdiutil create -volname "Everything-Mac" -srcfolder "$APP" -ov -format UDZO "$DMG"

# Notarize the DMG and staple the ticket so it runs offline.
xcrun notarytool submit "$DMG" --keychain-profile notary --wait
xcrun stapler staple "$DMG"

echo "Built + notarized: $(pwd)/$DMG"
