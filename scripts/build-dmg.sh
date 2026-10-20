#!/bin/zsh
# Builds a universal, ad-hoc signed Toolbox.app and packages it as build/Toolbox-<version>.dmg.
# Usage: scripts/build-dmg.sh [version]   (defaults to MARKETING_VERSION in project.yml)
# BUILD_NUMBER sets CFBundleVersion (defaults to 1).
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)}"
derived=build/DerivedData
app="$derived/Build/Products/Release/Toolbox.app"
dmg="build/Toolbox-$version.dmg"

xcodegen generate --quiet
xcodebuild -project Toolbox.xcodeproj -scheme Toolbox -configuration Release \
  -derivedDataPath "$derived" -destination 'generic/platform=macOS' \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-1}" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  -quiet build
codesign --verify --deep --strict "$app"

# Finder shows the app next to an Applications shortcut to drag it onto.
staging=$(mktemp -d)
ditto "$app" "$staging/Toolbox.app"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -volname "Toolbox $version" -srcfolder "$staging" -fs HFS+ -format UDZO -quiet "$dmg"
rm -rf "$staging"

echo "Built $dmg ($(lipo -archs "$app/Contents/MacOS/Toolbox"), version $version)"
