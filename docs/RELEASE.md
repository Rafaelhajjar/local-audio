# Release procedure

## Development preview

The current accepted scope is an ad hoc, unnotarized development prerelease. Developer ID access is unavailable. Keep production checks open and describe observed compatibility precisely.

1. Run `python3 scripts/check-source.py` and `swift test --scratch-path .build/integration`.
2. Run `./scripts/build-app.sh`. Test the bundled app: it includes both helpers, model manifests, icon, usage descriptions and licenses. Do not substitute `swift run` evidence for packaged behavior.
3. Use isolated app-state/recording folders and generated speech to verify explicit model setup, cancellation/repair, import, offline transcription, playback, timestamp seeking, export and recovery. For voice releases also verify Name This Voice, local profile persistence, cross-recording suggestions remaining Unknown, explicit confirmation/revocation and a different-voice control with networking denied. Separately verify consented physical capture, Stop & Save, quit while recording and relaunch. Record exact results and untested cases in VALIDATION.md and CHECKLIST.md. Keep private audio and model weights out of Git and release assets.
4. Verify the exact app's ad hoc signature with `codesign --verify --strict --deep --verbose=2 dist/LocalAudio.app` and check `SHA256SUMS.txt` from `dist/`. Ensure the ZIP includes its helper/resources but no test data or weights.
5. Publish that exact ZIP and checksum with a matching source tag, marked **prerelease**. State Apple silicon/macOS 15+, ad hoc signing, absent notarization, unverified clean-Mac/Gatekeeper installation, observed device evidence and remaining limitations. A downloaded copy may be blocked by macOS; retain the README's source-build route and do not instruct users to disable security protections.

The earlier 0.1 preview has 52 passing tests in hosted CI, generated-speech offline checks, built-in capture/save/playback/quit evidence and a limited system-default AirPods silence result. See VALIDATION.md for details. CI success is not a general hardware, ASR accuracy or Gatekeeper guarantee.

The 0.2.1 voice-feature suite passes 112 tests. It covers legacy-data decoding, extraction-recipe isolation, source-balanced matching, copied-window deduplication, preserved human confirmation history, unavailable-example recovery, stale refresh rejection, interrupted sidecar publication and confirmed-only exports. Both model packs remain optional; speaker suggestions never assign names automatically. Real-person recognition calibration remains open.

For upgrades from 0.2.0, keep original recordings and voice sidecars available, then use **People → Update Saved Voices**. This updates measurements for existing confirmed examples without creating labels or enrolling new examples. The updated bank/analysis schema is version 2; retain a local backup before reverting to an older preview.

## Future production release

1. Complete physical permission allow/deny, default/explicit devices, silence/no-buffer failure, USB/interface and Bluetooth speech, unplug/sleep, sustained disk pressure and quit checks. Test each claimed hardware class.
2. On a clean Mac/user account, verify permissions, model setup and complete workflow without developer caches. Characterize broader real-audio quality and total-system memory before making performance claims.
3. Use a Developer ID Application certificate and Apple notary credentials. Build with `SIGN_IDENTITY='Developer ID Application: ...' VERSION=0.2.0 ./scripts/build-app.sh`. The script applies hardened runtime and microphone entitlement. Verify the app's strict signature.
4. Set `NOTARY_PROFILE` to a configured `notarytool` keychain profile and run `./scripts/notarize.sh`. Only Apple's Accepted response plus successful stapling and Gatekeeper assessment establishes notarization. Never put credentials or exported certificates in the repository.
5. Publish the exact tested signed/stapled ZIP, checksum, source tag and concise compatibility/limitation notes. Update the production checklist only with observed evidence.

The repository contains no signing identity, provisioning profile or notary credentials. An ad hoc preview does not substitute for public Gatekeeper validation.
