#!/bin/bash
# Generate a single-release signed feed from the final notarized ZIP.
set -euo pipefail
version="$1"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
archive="dist/AIQuota-$version-arm64.zip"
tools=".build/artifacts/sparkle/Sparkle/bin"
feed_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiquota-appcast.XXXXXX")
cp "$archive" "$feed_dir/"
args=(--maximum-versions 1 --maximum-deltas 0 --download-url-prefix "https://github.com/praveenjuge/ai-quota/releases/download/v$version/" -o dist/appcast.xml)
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/generate_appcast" --ed-key-file - "${args[@]}" "$feed_dir"
else
    "$tools/generate_appcast" --account ai-quota "${args[@]}" "$feed_dir"
fi
# Check the feed structure and release identity before publication.
python3 - "$version" <<'PY'
import sys, xml.etree.ElementTree as ET
root=ET.parse('dist/appcast.xml')
ns={'s':'http://www.andymatuschak.org/xml-namespaces/sparkle'}
items=root.findall('./channel/item')
assert len(items)==1
item=items[0]
assert item.findtext('s:version', namespaces=ns)==sys.argv[1]
e=item.find('enclosure')
assert e.attrib['url']==f'https://github.com/praveenjuge/ai-quota/releases/download/v{sys.argv[1]}/AIQuota-{sys.argv[1]}-arm64.zip'
assert e.attrib['{'+ns['s']+'}edSignature']
assert int(e.attrib['length'])>0
PY
