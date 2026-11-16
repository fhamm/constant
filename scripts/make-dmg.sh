#!/bin/bash
# Builds Constant.app and packs it into a drag-to-Applications disk image.
# Accepts the same VERSION and UNIVERSAL variables as build.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh

VERSION="$(plutil -extract CFBundleShortVersionString raw build/Constant.app/Contents/Info.plist)"
DMG="build/Constant-$VERSION.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R build/Constant.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "Constant" -srcfolder "$STAGING" -format UDZO -quiet "$DMG"

echo "Built $DMG"
