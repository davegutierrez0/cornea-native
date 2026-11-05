#!/bin/bash
set -euo pipefail
# Full Xcode supplies the SwiftUI compiler plugins absent from some CLT releases.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"
APP="$ROOT/dist/Cornea Native.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/CorneaNative" "$APP/Contents/MacOS/CorneaNative"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
file "$APP/Contents/MacOS/CorneaNative"
echo "Built: $APP"
