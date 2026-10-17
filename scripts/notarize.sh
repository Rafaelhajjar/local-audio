#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your notarytool keychain profile}"
VERSION="${VERSION:-0.1.0}"
ZIP="dist/LocalAudio-$VERSION-macOS-arm64.zip"
[[ -f "$ZIP" ]] || { echo 'Build the signed release first.' >&2; exit 2; }
codesign --verify --strict --deep dist/LocalAudio.app
codesign -dvv dist/LocalAudio.app 2>&1 | /usr/bin/grep -q 'Authority=Developer ID Application:' || { echo 'A Developer ID signature is required.' >&2; exit 2; }
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > dist/notary-result.json
/usr/bin/python3 -c 'import json; assert json.load(open("dist/notary-result.json"))["status"] == "Accepted", "Notarization was not accepted"'
xcrun stapler staple dist/LocalAudio.app
xcrun stapler validate dist/LocalAudio.app
spctl --assess --type execute --verbose=2 dist/LocalAudio.app
ditto -c -k --sequesterRsrc --keepParent dist/LocalAudio.app "$ZIP"
(cd dist && shasum -a 256 "LocalAudio-$VERSION-macOS-arm64.zip" > SHA256SUMS.txt)
