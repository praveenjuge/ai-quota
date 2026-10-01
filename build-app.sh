#!/bin/sh
# Build a signed, self-contained AIQuota.app in dist/.
# Usage: ./build-app.sh
set -eu
cd "$(dirname "$0")"

IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Juge Praveen (LW385M78LW)}"

swift build -c release 2>&1 | tail -2

APP="dist/AIQuota.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AIQuota "$APP/Contents/MacOS/AIQuota"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --deep --options runtime --timestamp \
    --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP" && echo "signed OK"
echo "built: $APP"
