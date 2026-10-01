#!/bin/bash
# Build a self-contained, signed release bundle. Refuse existing output.
set -euo pipefail
cd "$(dirname "$0")"
version="${1:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' | sed 's/^v//')}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Expected major.minor.patch version' >&2; exit 1; }
app="${APP_OUTPUT:-dist/AIQuota.app}"
[ ! -e "$app" ] || { echo "Output already exists: $app; choose a fresh APP_OUTPUT." >&2; exit 1; }
identity="${CODESIGN_IDENTITY:-Developer ID Application: Juge Praveen (LW385M78LW)}"
build_args=(-c release --arch arm64)
# Hosted runners can inherit a shared SwiftPM artifact cache. Use a new
# directory for every release attempt, including reruns of the same job.
if [ -n "${RUNNER_TEMP:-}" ]; then
    cache_path=$(mktemp -d "$RUNNER_TEMP/aiquota-swiftpm.XXXXXX")
    build_args+=(--cache-path "$cache_path")
fi
build_log=$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/aiquota-build.XXXXXX")
if swift build "${build_args[@]}" 2>&1 | tee "$build_log"; then
    :
else
    build_exit=${PIPESTATUS[0]}
    [ "$build_exit" -ne 0 ] || exit 1
    # Retry only the known binary-artifact cache collision. Preserve the
    # failed cache and log; compiler, signing and other errors fail normally.
    if ! grep -Eq "error: failed downloading .*required by binary target .*[/]artifacts/.* already exists in file system" "$build_log"; then
        exit "$build_exit"
    fi
    echo "SwiftPM artifact cache collision; retrying once with a fresh cache. Log: $build_log"
    cache_path=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/aiquota-swiftpm.XXXXXX")
    build_args=(-c release --arch arm64 --cache-path "$cache_path")
    swift build "${build_args[@]}"
fi
bin=$(swift build "${build_args[@]}" --show-bin-path)
framework=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -d "$framework" ]
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin/AIQuota" "$app/Contents/MacOS/AIQuota"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
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
