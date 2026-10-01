#!/bin/bash
set -euo pipefail
source_app="$1"
root=$(mktemp -d "${TMPDIR:-/tmp}/aiquota-menu-feedback.XXXXXX")
app="$root/AIQuota.app"
ditto "$source_app" "$app"
framework="$app/Contents/Frameworks"
sources=()
for source in Sources/AIQuota/*.swift; do
    [[ "$source" == */AIQuotaApp.swift ]] || sources+=("$source")
done
swiftc -swift-version 6 -O -parse-as-library -F "$framework" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    "${sources[@]}" scripts/MenuFeedbackE2E.swift -o "$root/MenuFeedbackE2E"
# This is a fresh test copy; preserve the original copied executable as evidence.
cp "$root/MenuFeedbackE2E" "$app/Contents/MacOS/MenuFeedbackE2E"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable MenuFeedbackE2E' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.praveenjuge.ai-quota.menu-e2e.$(uuidgen)" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 999.0.0' "$app/Contents/Info.plist"
codesign --force --options runtime --timestamp --sign 'Developer ID Application: Juge Praveen (LW385M78LW)' "$app"
"$app/Contents/MacOS/MenuFeedbackE2E" "$root" > "$root/results.txt" 2>&1
cat "$root/results.txt"
printf 'Artifacts: %s\n' "$root"
