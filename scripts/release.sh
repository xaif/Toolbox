#!/bin/zsh
# Builds a Developer ID–signed, notarized DMG for distribution outside the Mac App Store.
#
# One-time setup:
#   1. Create a "Developer ID Application" certificate (Xcode › Settings › Accounts › Manage Certificates).
#   2. Store notarization credentials:
#        xcrun notarytool store-credentials toolbox-notary --apple-id you@example.com --team-id TEAMID
#
# Usage: TEAM_ID=TEAMID scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="${TEAM_ID:?Set TEAM_ID to your Apple Developer team ID}"
NOTARY_PROFILE="${NOTARY_PROFILE:-toolbox-notary}"
VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"(.*)".*/\1/')
OUT=build/release
rm -rf "$OUT" && mkdir -p "$OUT"

xcodegen generate --quiet
xcodebuild -project Toolbox.xcodeproj -scheme Toolbox -configuration Release \
  -archivePath "$OUT/Toolbox.xcarchive" \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_IDENTITY="Developer ID Application" CODE_SIGN_STYLE=Manual \
  OTHER_CODE_SIGN_FLAGS="--timestamp" archive -quiet

APP="$OUT/Toolbox.xcarchive/Products/Applications/Toolbox.app"
codesign --verify --deep --strict --verbose=2 "$APP"

DMG="$OUT/Toolbox-$VERSION.dmg"
STAGE="$OUT/dmg"
mkdir -p "$STAGE" && cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Toolbox" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
codesign --sign "Developer ID Application" --timestamp "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
echo "Release ready: $DMG"
