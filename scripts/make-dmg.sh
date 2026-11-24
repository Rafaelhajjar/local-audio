#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/dist/LocalAudio.app"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
VERSION="${VERSION:-$APP_VERSION}"
[[ "$VERSION" == "$APP_VERSION" ]] || { echo 'VERSION does not match the packaged app.' >&2; exit 2; }
MODE=--preview
if [[ "${PRODUCTION:-0}" == 1 ]]; then
    : "${SIGN_IDENTITY:?Set a Developer ID Application signing identity}"
    : "${NOTARY_PROFILE:?Set a notarytool keychain profile}"
    MODE=--notarized
fi
./scripts/verify-app.sh "$APP" "$MODE"
STAGING="$(mktemp -d "$PWD/dist/.installer.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir "$STAGING/content"
ditto "$APP" "$STAGING/content/LocalAudio.app"
ln -s /Applications "$STAGING/content/Applications"
if [[ "${PRODUCTION:-0}" == 1 ]]; then
    NOTICE='Developer ID signed and notarized by Apple.'
else
    NOTICE='DEVELOPMENT PREVIEW: ad hoc signed and unnotarized. macOS may block it. This is not a production installer. Do not disable security protections.'
fi
cat > "$STAGING/content/Start Here.txt" <<TEXT
LocalAudio $VERSION

Drag LocalAudio into Applications, then open it from Applications.
Requires Apple silicon and macOS 15 or newer.
$NOTICE

Quick start guides you through a short recording and optional English model setup.
Recording begins only when you press Record or enable automatic recording.
Model setup downloads about 464 MB;
audio and transcripts stay on your Mac. No account is required.

Removing the app leaves your recordings and installed models in place.
Support and source: https://github.com/Rafaelhajjar/local-audio
TEXT
DMG="$PWD/dist/LocalAudio-$VERSION-macOS-arm64.dmg"
[[ ! -L "$DMG" ]] || { echo 'Refusing a linked disk-image destination.' >&2; exit 2; }
hdiutil create -volname "LocalAudio $VERSION" -srcfolder "$STAGING/content" -format UDZO -ov "$STAGING/LocalAudio.dmg" >/dev/null
if [[ "${PRODUCTION:-0}" == 1 ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$STAGING/LocalAudio.dmg"
    xcrun notarytool submit "$STAGING/LocalAudio.dmg" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > dist/notary-dmg-result.json
    python3 -c 'import json; assert json.load(open("dist/notary-dmg-result.json")).get("status") == "Accepted", "DMG notarization was not accepted"'
    xcrun stapler staple "$STAGING/LocalAudio.dmg"
    xcrun stapler validate "$STAGING/LocalAudio.dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$STAGING/LocalAudio.dmg"
fi
mv -f "$STAGING/LocalAudio.dmg" "$DMG"
(cd dist && shasum -a 256 "LocalAudio-$VERSION-macOS-arm64.zip" "LocalAudio-$VERSION-macOS-arm64.dmg" > SHA256SUMS.txt)
echo "Created $DMG"
