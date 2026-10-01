#!/bin/bash
# Prepare isolated signed app copies and a signed localhost feed. No production
# preferences, app bundles, credentials, or releases are modified.
set -euo pipefail
source_app="$1"
new_version="${2:-0.1.3}"
[[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
root="$(mktemp -d "${TMPDIR:-/tmp}/aiquota-update-e2e.XXXXXX")"
test_id="com.praveenjuge.ai-quota.update-e2e.$(uuidgen | tr '[:upper:]' '[:lower:]')"
identity="${CODESIGN_IDENTITY:-Developer ID Application: Juge Praveen (LW385M78LW)}"
tools="$(pwd)/.build/artifacts/sparkle/Sparkle/bin"
mkdir -p "$root/installed" "$root/feed" "$root/new"
for folder in installed new; do
    ditto "$source_app" "$root/$folder/AIQuota.app"
    python3 - "$root/$folder/AIQuota.app/Contents/Info.plist" "$folder" "$test_id" "$new_version" <<'PY'
import sys,plistlib
p=sys.argv[1]
with open(p,'rb') as f:d=plistlib.load(f)
v='0.1.2' if sys.argv[2]=='installed' else sys.argv[4]
d.update(CFBundleIdentifier=sys.argv[3],CFBundleVersion=v,CFBundleShortVersionString=v,SUFeedURL='http://127.0.0.1:18765/appcast.xml',NSAppTransportSecurity={'NSAllowsLocalNetworking':True})
with open(p,'wb') as f:plistlib.dump(d,f)
PY
    codesign --force --options runtime --timestamp --sign "$identity" "$root/$folder/AIQuota.app"
done
ditto -c -k --sequesterRsrc --keepParent "$root/new/AIQuota.app" "$root/feed/AIQuota-$new_version-arm64.zip"
"$tools/generate_appcast" --account ai-quota --maximum-versions 1 --maximum-deltas 0 --download-url-prefix http://127.0.0.1:18765/ "$root/feed"
# Disable provider reads for the isolated test identity.
for provider in codex claude muse; do
    defaults write "$test_id" "provider.$provider.enabled" -bool false
done
defaults write "$test_id" verificationMarker -string retained
printf '%s\n' "$root"
