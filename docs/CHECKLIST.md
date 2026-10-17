# Release checklist

The product stays small: one local Mac app, standard microphone inputs, imported audio, optional English transcription, confirmed local voice profiles, playback and export. These five milestones track the path from development preview to a production release. A checked source task does not establish hardware or distribution behavior.

Coordinator owns shared integration, review, public repository and releases. Capture and model workers own their disjoint source areas; tests use generated fixtures. Every milestone requires a concrete result and evidence before it is called complete.

## Accepted development preview

On 2026-10-17 the owner approved microphone testing and chose an ad hoc development preview because Apple Developer signing access is unavailable. Production signing and broader compatibility checks remain future work below.

- [x] Separate public source repository, reproducible build, dependency/privacy checks and 52 passing tests in hosted CI.
- [x] Explicit in-app model setup and packaged offline transcription verified with generated speech.
- [x] Packaged built-in microphone capture/save/playback, graceful quit while recording and relaunch verified.
- [x] System-default input path saved valid 24 kHz mono silence from connected AirPods Pro; Bluetooth speech quality remains unverified.
- [x] Publish the exact tested ZIP, checksum and matching source tag as a clearly limited, ad hoc, unnotarized prerelease. Anonymous public downloads match the local bytes.

## Local voice profiles (0.2 preview)

- [x] Optional explicit speaker-model setup, pinned hashes, retained license/provenance and real local model-load validation.
- [x] Anonymous turns with playback and Name This Voice; choose a saved person or create a local profile.
- [x] Atomic private profile/confirmation storage; rename, forget and Keep Unknown revoke associated examples without changing audio/transcripts.
- [x] Compare later recordings to confirmed clean examples; exclude same recording/content, weak and ambiguous matches.
- [x] Keep every suggestion separate from Unknown; only explicit confirmation assigns a name or adds an example.
- [x] Require the reviewed analysis snapshot and turn geometry when confirming; reject stale naming actions after reanalysis.
- [x] Conservative confirmed-name display/export; mixed or insufficiently covered transcript chunks stay Unknown.
- [x] Generated fixtures cover persistence, revocation, corruption, source drift, stale actions, cross-recording leakage and worker derivative cleanup.
- [x] Packaged in-app model setup, generated same-voice suggestion/confirm/revoke and different-voice offline control verified.
- [ ] Real consented multi-person evaluation across microphones, rooms, accents and days. Suggestions are experimental, with no calibrated identity-accuracy claim.

## 1. A reliable recorder

- [x] Enumerate normal AVFoundation inputs and offer system default plus explicit selection, without DJI-specific filtering.
- [x] Ask for microphone permission only after Start; report denied permission with a useful next action.
- [x] Separate capture/writing from the main thread. Require successfully appended audio before claiming Recording.
- [x] Save unique CAF originals through hidden staging; stop intentionally, including during startup. Silence remains valid audio.
- [x] Surface buffer, disk, missing input, runtime and device-disconnect failures. Never silently switch an explicitly chosen device mid-recording.
- [x] Bound finalization independently from the writer queue; reopen/verify rate and frames before publishing a completed recording. Preserve/report incomplete recovery files on failure.
- [x] Exercise the production CAF writer with generated mono/stereo PCM; verify exact decoded samples and safe silence, empty-input, format-change, completion-denied and destination-collision behavior.
- [x] Packaged-app permission approval, built-in capture/save/playback, deliberate stop, quit during recording and relaunch verified on one Mac.
- [x] System-default input delivered and saved valid silent PCM from AirPods Pro without a speech threshold.
- [ ] Permission denial, missing-buffer failures, unplug/sleep and sustained disk-pressure behavior verified with physical inputs.
- [ ] USB/interface and broader Bluetooth behavior, including speech quality, tested before broad compatibility claims.

## 2. One understandable local library

- [x] Keep audio in an ordinary chosen folder; preserve imported sources and edit titles/dates through sidecars.
- [x] Verify imported copies by hash, detect duplicate content, reject unfinished/invalid files, and keep same-stem formats separate.
- [x] Report unreadable library files without deleting or rewriting them; preserve unreadable settings/jobs for recovery.
- [x] Provide playback, seeking, speed controls, transcript search, timestamp jumps and readable text export in one interface.
- [x] Persist sequential jobs, restore interrupted work, cancel children on pause/quit, and retain original audio/earlier transcripts on failure.
- [x] Wait for saved-recording registration during quit and prevent folder changes while registration is pending.
- [x] Packaged UI import/play/seek/title/export/relaunch and missing-file/renamed-file job retry verified using generated speech.
- [x] Manual recorded-date picker edit and restoration verified; metadata date persistence is also covered by fixture tests.

## 3. Explicit model setup and offline transcription

- [x] Pin a complete English pack to an immutable source revision with file sizes, SHA-256/Git-blob hashes and license attribution.
- [x] Stream downloads, preflight space, bound retries, reuse verified files, cancel cleanly and activate only after hash checks plus actual Core ML load.
- [x] Keep old installs on failure; read selected external folders without modifying them. Startup performs local checks only.
- [x] Bundle an offline helper that manually loads the selected models; no SDK automatic model discovery, repair or download.
- [x] Wait for model setup/validation shutdown on quit and locate the model manifest within the packaged app resources.
- [x] Real explicit in-app download, cancellation/retry, corruption/repair and relaunch verified in isolated state.
- [x] Generated English speech transcribed by the packaged helper with network and developer build-cache reads denied; resulting words/timings reviewed.
- [x] Generated 15-minute file exercises disk-backed processing and process memory was measured.
- [ ] Broader real-audio durations and total-system memory characterized before broad performance claims.

## 4. A reproducible public repository

- [x] Fresh source tree; user recordings and model caches remain separate from development data.
- [x] Retain frozen dependency source/licenses and check its file hashes. No private audio, models, logs or credentials in Git.
- [x] Add build/package scripts, native icon, microphone usage description, bundled helper/resources and automated source/fixture checks.
- [x] Document installation, local data locations, model sources, architecture and current limits.
- [x] Integrated test suite, source checks and packaged build pass.
- [x] Publish reviewed source to the new public GitHub repository and verify all required files in a fresh clone.
- [x] Initial published revision passes hosted CI.
- [x] Recovery changes pass hosted CI.
- [x] Final command-state, shared-state and packaging changes pass hosted CI.

## 5. Future production Mac release

- [ ] Validate from a clean user/Mac without developer model or build caches; no account required.
- [ ] Verify all required user flows against the exact app/ZIP being released and record test platform/device evidence.
- [ ] Developer ID sign with hardened runtime, notarize, staple and verify Gatekeeper using authorized Apple credentials.
- [ ] Publish the tested signed/notarized production app ZIP, checksum, source tag, supported platforms and honest limitations.
- [x] Recheck protected project source hashes and confirm development did not alter existing user apps or archives.

## Evidence log

- Model worker: 17 isolated Swift 6 fixture tests passed, including streaming transport, integrity, retry, cancellation, rollback, packaged-resource lookup and multiple shutdown waiters. No actual weights downloaded by those tests.
- Capture worker: 13 capture invariant tests and seven actual native CAF writer tests passed. The integrated suite now passes **52 tests** with networking denied. No microphone or device enumeration was used by these tests; separate physical evidence is recorded below.
- Fresh local-source build/test with network denied: **45 tests passed**, zero failures. The optional upstream NeMo binary is excluded. The initial nested SwiftPM sandbox attempt failed to apply; the successful run used an outer deny-network profile and disabled only SwiftPM's nested manifest sandbox.
- All **653 frozen dependency files** also matched the official GitHub archive of the declared revision.
- Packaged helper transcribed generated 13-second English speech with network and all `.build` reads denied. Words matched the intended sample; this is a functional smoke test, not an ASR accuracy benchmark.
- Packaged UI verified model download/activation, import, original/copy SHA-256 equality, automatic local transcript, timestamp jump/playback, title edit and local text export. Test data was generated and stored separately from existing archives.
- An initial developer override under Documents waited in an OS directory-open call; temporary-folder validation succeeded. Folder loading is now visible and Settings remains available for choosing a folder. Permission keys explain user-selected protected folders. Folder permission allow/deny still requires explicit integration verification.
- Developer ID identity was absent from this machine. The owner explicitly accepted development-preview distribution; signing/notarization remain production work.

- Public repository: https://github.com/Rafaelhajjar/local-audio. Initial published revision `77ebed9`. Fresh public-clone source check passed all 690 files / 653 dependency hashes; fresh build/tests with network denied passed 45 tests.
- Real app model repair cancellation preserved Ready state and selection. A one-byte alteration in a disposable copied joint graph was rejected on relaunch; explicit repair reused verified staging files, downloaded the remainder, loaded Core ML and activated a new valid pack. The original downloaded test pack and existing user caches were untouched.
- Stop-before-permission completes in the packaged UI. The owner subsequently approved macOS microphone access; the physical capture checks below used isolated folders with automatic transcription disabled.

- The current packaged UI recovered a persisted failed job after the generated audio and both sidecars were renamed. Retry used the new path, preserved original bytes and cleared the work list after success. Failed jobs now have a direct Retry action and an accurate needs-attention summary.
- A generated 910.109-second WAV completed with network/developer-cache reads denied. All 70 expected repeated phrases were present, final timestamp 910.08s. See VALIDATION.md for timing/memory context and limits.
- Initial hosted CI passed: https://github.com/Rafaelhajjar/local-audio/actions/runs/39058212907. This does not establish hardware, clean-user or notarization gates.

- Recovery-source CI passed: https://github.com/Rafaelhajjar/local-audio/actions/runs/39059122498.
- Native date picker changed and saved the generated recording date, then restored it. The Recording menu observes capture directly: Start disables and Stop enables while permission is pending; Stop returns the app to Ready.

- Capture/model readiness now propagates to dependent store views without forwarding audio-meter ticks. Packaged Settings was verified to disable its folder chooser during microphone startup and re-enable it after native-menu Stop.

- App-state/build validation passed on `a2e664d`: https://github.com/Rafaelhajjar/local-audio/actions/runs/39060363575. All 45 tests, source checks, app packaging and artifact upload passed.

- Native-writer validation passed on `d935a71`: https://github.com/Rafaelhajjar/local-audio/actions/runs/39061835600. All **52 tests**, source checks, app packaging and artifact upload passed. The updated local app/ZIP passed strict ad hoc signature verification and checksum validation; it includes no audio, private sidecars or model weights. All 725 protected earlier-project source files still match their baseline hashes.

- After human microphone approval, the exact packaged app saved 7.8716 seconds of built-in 44.1 kHz mono audio (347,136 decoded frames), played it in the UI, and returned to Ready. Quitting during another recording produced 4.8762 seconds (215,040 frames), saved metadata and exited with no incomplete file or pending job. Relaunch restored the saved library.
- The system-default path resolved to connected AirPods Pro and saved 8.54 seconds of 24 kHz mono PCM (204,960 frames). Every sample was zero: this verifies valid-silence handling and finalization, not Bluetooth speech quality. No microphone audio or derived transcript was uploaded or committed. The isolated test app was closed after verification.
- Development preview published: https://github.com/Rafaelhajjar/local-audio/releases/tag/v0.1.0-preview.1. Source tag points to `a46aa38`; runtime/build sources match CI-validated `d935a71`. Anonymous ZIP/checksum downloads match the tested local files. ZIP SHA-256: `59a59bac991c98a1d3124e9603c8a2af2066ee73463742819cad1891c7cc68b4`.

- Voice feature 0.2: **88 tests** passed normally and with network denied. Final packaged profile persistence, new-person naming, possible-match confirmation and native reanalysis passed; final packaged speaker helper also passed a different-voice offline control. Scratch files were cleared, generated originals retained their hashes, all 725 protected source files and 653 frozen dependency files were unchanged. See the 0.2 section in VALIDATION.md for exact evidence and limits.
