#!/bin/bash
# Require an accepted notarization and print Apple's rejection log on failure.
set -euo pipefail
archive="$1"
result=$(mktemp "$RUNNER_TEMP/notary-result.XXXXXX")
auth=(--apple-id "$APPLE_ID" --password "$APP_SPECIFIC" --team-id LW385M78LW)
if ! xcrun notarytool submit "$archive" "${auth[@]}" \
    --wait --timeout 20m --output-format json > "$result"; then
  cat "$result"
  echo "::error::Notarization submission failed for $(basename "$archive")"
  exit 1
fi
cat "$result"
if [ "$(jq -r '.status' "$result")" != "Accepted" ]; then
  submission_id=$(jq -r '.id' "$result")
  xcrun notarytool log "$submission_id" "${auth[@]}" || true
  echo "::error::Notarization was not accepted for $(basename "$archive")"
  exit 1
fi
