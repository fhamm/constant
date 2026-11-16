#!/bin/bash
# Builds Constant.app into ./build using only the Command Line Tools.
#   VERSION=1.2.3 ./build.sh   overrides the version in Info.plist
#   UNIVERSAL=1 ./build.sh     builds for both Apple Silicon and Intel
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Constant.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ "${UNIVERSAL:-0}" = "1" ]; then
    BINS=()
    for ARCH in arm64 x86_64; do
        FLAGS=(-c release --build-system native --triple "$ARCH-apple-macosx")
        swift build "${FLAGS[@]}"
        BINS+=("$(swift build "${FLAGS[@]}" --show-bin-path)/Constant")
    done
    lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/Constant"
else
    swift build -c release --build-system native
    cp "$(swift build -c release --build-system native --show-bin-path)/Constant" "$APP/Contents/MacOS/Constant"
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ -n "${VERSION:-}" ]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
fi

# Ad-hoc signature, no hardened runtime, so third-party Audio Units can load in-process.
codesign --force --sign - "$APP"

echo "Built $APP"
