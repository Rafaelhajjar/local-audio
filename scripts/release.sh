#!/bin/bash
# Prepare production artifacts locally. This script never publishes a release.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGN_IDENTITY:?Set your Developer ID Application signing identity}"
: "${NOTARY_PROFILE:?Set your notarytool keychain profile}"
[[ "$SIGN_IDENTITY" != - ]] || { echo 'Production releases require Developer ID signing.' >&2; exit 2; }
[[ -z "$(git status --porcelain)" ]] || { echo 'Commit the reviewed source before preparing a production release.' >&2; exit 2; }
export SIGN_IDENTITY NOTARY_PROFILE
rm -f dist/release-receipt.json
python3 scripts/check-source.py --tracked
swift test --scratch-path .build/tests
./scripts/build-app.sh
./scripts/notarize.sh
PRODUCTION=1 ./scripts/make-dmg.sh
./scripts/verify-app.sh "$PWD/dist/LocalAudio.app" --notarized
python3 - <<'PY'
import hashlib, json, pathlib, plistlib, subprocess
root = pathlib.Path.cwd()
dist = root / 'dist'
info = plistlib.loads((dist / 'LocalAudio.app/Contents/Info.plist').read_bytes())
v = info['CFBundleShortVersionString']
artifacts = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in [dist/f'LocalAudio-{v}-macOS-arm64.zip', dist/f'LocalAudio-{v}-macOS-arm64.dmg']}
receipt = {'version':v,'build':info['CFBundleVersion'],'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'artifacts':artifacts,'notarization':{k:json.loads((dist/f'notary-{k}-result.json').read_text()) for k in ['app','dmg']},'hardwareAndCleanMacValidation':'See docs/RELEASE-TESTING.md; not established by this script.'}
(dist/'release-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
PY
echo 'Signed, notarized artifacts and release-receipt.json are in dist/. Nothing has been published.'
