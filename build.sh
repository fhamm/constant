#!/bin/bash
# Builds Constant.app into ./build using only the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --build-system native
BIN="$(swift build -c release --build-system native --show-bin-path)/Constant"

APP="build/Constant.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Constant"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature, no hardened runtime, so third-party Audio Units can load in-process.
codesign --force --sign - "$APP"

echo "Built $APP"
