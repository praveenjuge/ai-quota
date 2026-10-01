#!/bin/bash
# Build a self-contained, signed release bundle. Refuse existing output.
set -euo pipefail
cd "$(dirname "$0")"
version="${1:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' | sed 's/^v//')}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Expected major.minor.patch version' >&2; exit 1; }
app="${APP_OUTPUT:-dist/AIQuota.app}"
[ ! -e "$app" ] || { echo "Output already exists: $app; choose a fresh APP_OUTPUT." >&2; exit 1; }
identity="${CODESIGN_IDENTITY:-Developer ID Application: Juge Praveen (LW385M78LW)}"
swift build -c release --arch arm64
bin=$(swift build -c release --arch arm64 --show-bin-path)
framework=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -d "$framework" ]
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin/AIQuota" "$app/Contents/MacOS/AIQuota"
cp Resources/Info.plist "$app/Contents/Info.plist"
ditto "$framework" "$app/Contents/Frameworks/Sparkle.framework"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
# Use the semantic version for both comparison fields, including local builds.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app/Contents/Info.plist"
codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
# Sign nested executable bundles from the inside out, preserving Sparkle's entitlements.
while IFS= read -r component; do
    codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$identity" "$component"
done < <(find "$app/Contents/Frameworks" -depth \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' \) -type d)
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --deep --strict --verbose "$app"
echo "built: $app ($version)"
