#!/bin/bash
# Read-only validation; --notarized also asks Gatekeeper and checks the ticket.
set -euo pipefail
APP="${1:?Usage: verify-app.sh /path/to/LocalAudio.app [--developer-id|--notarized]}"
MODE="${2:---preview}"
case "$MODE" in --preview|--developer-id|--notarized) ;; *) echo 'Unknown verification mode' >&2; exit 2;; esac
[[ -d "$APP" && ! -L "$APP" ]] || { echo 'Expected a real app directory.' >&2; exit 2; }
codesign --verify --strict --deep --verbose=2 "$APP"
plutil -lint "$APP/Contents/Info.plist"
APP_TEAM=""
for RELATIVE in Contents/MacOS/LocalAudio Contents/Helpers/local-audio-transcriber Contents/Helpers/local-audio-speakers; do
    BINARY="$APP/$RELATIVE"
    lipo "$BINARY" -verify_arch arm64
    if [[ "$MODE" != --preview ]]; then
        DETAILS="$(codesign -dvv "$BINARY" 2>&1)"
        echo "$DETAILS" | /usr/bin/grep -q 'Authority=Developer ID Application:' || { echo "Missing Developer ID: $RELATIVE" >&2; exit 2; }
        echo "$DETAILS" | /usr/bin/grep -q 'flags=.*runtime' || { echo "Missing hardened runtime: $RELATIVE" >&2; exit 2; }
        echo "$DETAILS" | /usr/bin/grep -q '^Timestamp=' || { echo "Missing secure timestamp: $RELATIVE" >&2; exit 2; }
        TEAM="$(echo "$DETAILS" | sed -n 's/^TeamIdentifier=//p')"
        [[ -n "$TEAM" && "$TEAM" != not\ set ]] || { echo 'Missing signing team.' >&2; exit 2; }
        if [[ -n "${APP_TEAM:-}" && "$TEAM" != "$APP_TEAM" ]]; then echo 'App and helpers have different signing teams.' >&2; exit 2; fi
        APP_TEAM="$TEAM"
    fi
done
if [[ "$MODE" != --preview ]]; then
    codesign -d --entitlements :- "$APP" 2>/dev/null | python3 -c 'import sys,plistlib; p=plistlib.load(sys.stdin.buffer); assert p.get("com.apple.security.device.audio-input") is True; assert not p.get("com.apple.security.get-task-allow",False), "Debug entitlement in release"'
fi
if [[ "$MODE" == --notarized ]]; then
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
fi
echo "App verification passed ($MODE)."
