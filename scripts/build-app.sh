#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd -P)"
VERSION="${VERSION:-0.2.1}"
BUILD_NUMBER="${BUILD_NUMBER:-2}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'VERSION must be x.y.z' >&2; exit 2; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo 'BUILD_NUMBER must be numeric' >&2; exit 2; }
[[ "$(uname -s)" == Darwin ]] || { echo 'Build this Mac app on macOS.' >&2; exit 2; }
swift build --scratch-path .build/app --arch arm64 -c release
BIN="$(swift build --scratch-path .build/app --arch arm64 -c release --show-bin-path)"
[[ ! -L dist ]] || { echo 'dist must be a real folder inside this checkout.' >&2; exit 2; }
mkdir -p dist
[[ ! -L "$ROOT/dist/LocalAudio.app" ]] || { echo 'Refusing to replace a linked app destination.' >&2; exit 2; }
STAGING="$(mktemp -d "$ROOT/dist/.package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/LocalAudio.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/LocalAudio" "$APP/Contents/MacOS/LocalAudio"
cp "$BIN/local-audio-transcriber" "$APP/Contents/Helpers/local-audio-transcriber"
cp "$BIN/local-audio-speakers" "$APP/Contents/Helpers/local-audio-speakers"
for BUNDLE in "$BIN"/*.bundle; do
    [[ -d "$BUNDLE" ]] && ditto "$BUNDLE" "$APP/Contents/Resources/$(basename "$BUNDLE")"
done
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/ThirdPartyLicenses"
cp vendor/FluidAudio/LICENSE "$APP/Contents/Resources/ThirdPartyLicenses/FluidAudio-LICENSE"
cp vendor/FluidAudio/ThirdPartyLicenses/* "$APP/Contents/Resources/ThirdPartyLicenses/"
swift scripts/make-icon.swift "$STAGING/LocalAudio.iconset"
iconutil -c icns "$STAGING/LocalAudio.iconset" -o "$APP/Contents/Resources/LocalAudio.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LocalAudio</string>
<key>CFBundleIdentifier</key><string>io.github.rafaelhajjar.LocalAudio</string>
<key>CFBundleName</key><string>LocalAudio</string>
<key>CFBundleDisplayName</key><string>LocalAudio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>CFBundleIconFile</key><string>LocalAudio</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSDocumentsFolderUsageDescription</key><string>LocalAudio reads audio in the recording folder you choose and saves recordings and transcripts there.</string>
<key>NSDesktopFolderUsageDescription</key><string>LocalAudio accesses audio files and recording folders that you choose.</string>
<key>NSDownloadsFolderUsageDescription</key><string>LocalAudio imports audio files and uses recording folders that you choose.</string>
<key>NSMicrophoneUsageDescription</key><string>LocalAudio uses your selected microphone to save audio recordings on your Mac.</string>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
xattr -cr "$APP"
if [[ "$SIGN_IDENTITY" == - ]]; then
    codesign --force --sign - "$APP/Contents/Helpers/local-audio-transcriber"
    codesign --force --sign - "$APP/Contents/Helpers/local-audio-speakers"
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/local-audio-transcriber"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/local-audio-speakers"
    codesign --force --options runtime --timestamp --entitlements Resources/LocalAudio.entitlements --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict --deep --verbose=2 "$APP"
rm -rf "$ROOT/dist/LocalAudio.app"
mv "$APP" "$ROOT/dist/LocalAudio.app"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/dist/LocalAudio.app" "$ROOT/dist/LocalAudio-$VERSION-macOS-arm64.zip"
(cd "$ROOT/dist" && shasum -a 256 "LocalAudio-$VERSION-macOS-arm64.zip" > SHA256SUMS.txt)
echo "Built dist/LocalAudio.app and ZIP ($SIGN_IDENTITY signing)."
