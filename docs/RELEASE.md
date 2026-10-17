# Release procedure

1. Run `python3 scripts/check-source.py` and `swift test --scratch-path .build/integration`.
2. Run `./scripts/build-app.sh`. Test the bundled app, not only `swift run`: it includes the helper, model manifest, icon, usage description and licenses.
3. Use isolated app-state/recording folders and generated speech to verify explicit model download, cancellation/retry, relaunch, import, transcription with network denied, playback, timestamp seeking and text export. Verify recording separately with consented hardware tests: permission allow/deny, default and explicit devices, stop, silence, unplug and quit. Record exact evidence in CHECKLIST.md.
4. On a clean Mac/user account, verify permissions, model setup and complete workflow without developer caches. Test each claimed hardware class. Keep unsupported/unverified claims out of the release notes.
5. For public distribution, use a Developer ID Application certificate and Apple notary credentials. Build with `SIGN_IDENTITY='Developer ID Application: ...' VERSION=0.1.0 ./scripts/build-app.sh`. The script applies hardened runtime and microphone entitlement to the main app. Verify `codesign --verify --strict --deep --verbose=2 dist/LocalAudio.app`.
6. Set `NOTARY_PROFILE` to a configured `notarytool` keychain profile and run `./scripts/notarize.sh`. Review Apple's result; only an Accepted response plus successful staple/assessment establishes notarization. Do not publish signing credentials or export certificates into the repository.
7. Publish the tested signed/stapled ZIP and SHA-256 with a Git tag/release and concise known limits. A development preview must be marked prerelease and must clearly describe its ad hoc signature. Hosted CI success does not establish real microphone, ASR accuracy or Gatekeeper behavior.

The repository does not contain a signing identity, provisioning profile or notary credentials. A local ad hoc build is reviewable and runnable on the developer machine but is not a substitute for public Gatekeeper validation. Do not instruct users to disable security protections.
