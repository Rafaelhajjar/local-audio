#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your notarytool keychain profile}"
APP="$PWD/dist/LocalAudio.app"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
VERSION="${VERSION:-$APP_VERSION}"
[[ "$VERSION" == "$APP_VERSION" ]] || { echo 'VERSION does not match the packaged app.' >&2; exit 2; }
./scripts/verify-app.sh "$APP" --developer-id
ZIP="$PWD/dist/LocalAudio-$VERSION-macOS-arm64.zip"
# Submit a new archive of this exact verified app, never an older ZIP.
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > dist/notary-app-result.json
python3 -c 'import json; r=json.load(open("dist/notary-app-result.json")); assert r.get("status") == "Accepted", "Notarization was not accepted; inspect dist/notary-app-result.json"'
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
./scripts/verify-app.sh "$APP" --notarized
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd dist && shasum -a 256 "LocalAudio-$VERSION-macOS-arm64.zip" > SHA256SUMS.txt)
echo "Notarized and stapled $ZIP"
