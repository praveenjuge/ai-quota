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

if codesign --force --deep --options runtime --timestamp \
    --sign "$IDENTITY" "$APP" 2>/dev/null; then
    codesign --verify --strict "$APP" && echo "signed OK ($IDENTITY)"
else
    echo "note: '$IDENTITY' unavailable, falling back to ad-hoc signature"
    codesign --force --deep --sign - "$APP"
    codesign --verify "$APP" && echo "signed OK (ad-hoc)"
fi
echo "built: $APP"
