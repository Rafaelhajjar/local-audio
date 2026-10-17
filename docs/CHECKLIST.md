# Release checklist

The product stays small: one local Mac app, standard microphone inputs, imported audio, optional English transcription, playback and export. These five milestones replace the earlier large planning framework. A checked source task does not establish hardware or distribution behavior.

Coordinator owns shared integration, review, public repository and releases. Capture and model workers own their disjoint source areas; tests use generated fixtures. Every milestone requires a concrete result and evidence before it is called complete.

## 1. A reliable recorder

- [x] Enumerate normal AVFoundation inputs and offer system default plus explicit selection, without DJI-specific filtering.
- [x] Ask for microphone permission only after Start; report denied permission with a useful next action.
- [x] Separate capture/writing from the main thread. Require successfully appended audio before claiming Recording.
- [x] Save unique CAF originals through hidden staging; stop intentionally, including during startup. Silence remains valid audio.
- [x] Surface buffer, disk, missing input, runtime and device-disconnect failures. Never silently switch an explicitly chosen device mid-recording.
- [x] Bound finalization independently from the writer queue; reopen/verify rate and frames before publishing a completed recording. Preserve/report incomplete recovery files on failure.
- [ ] Packaged-app permission allow/deny, deliberate stop, quit during recording, silence and no-audio failures verified.
- [ ] Built-in, USB/interface and Bluetooth classes each tested; publish only the compatibility actually established.

## 2. One understandable local library

- [x] Keep audio in an ordinary chosen folder; preserve imported sources and edit titles/dates through sidecars.
- [x] Verify imported copies by hash, detect duplicate content, reject unfinished/invalid files, and keep same-stem formats separate.
- [x] Report unreadable library files without deleting or rewriting them; preserve unreadable settings/jobs for recovery.
- [x] Provide playback, seeking, speed controls, transcript search, timestamp jumps and readable text export in one interface.
- [x] Persist sequential jobs, restore interrupted work, cancel children on pause/quit, and retain original audio/earlier transcripts on failure.
- [x] Wait for saved-recording registration during quit and prevent folder changes while registration is pending.
- [x] Packaged UI import/play/seek/title/export/relaunch and missing-file/renamed-file job retry verified using generated speech.
- [ ] Manual recorded-date picker edit verified; metadata date persistence is covered by fixture tests.

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

- [x] Fresh project/source tree with the original recorder, archive and earlier development project left separate.
- [x] Retain frozen dependency source/licenses and check its file hashes. No private audio, models, logs or credentials in Git.
- [x] Add build/package scripts, native icon, microphone usage description, bundled helper/resources and automated source/fixture checks.
- [x] Document installation, local data locations, model sources, architecture and current limits.
- [x] Integrated test suite, source checks and packaged build pass.
- [x] Publish reviewed source to the new public GitHub repository and verify all required files in a fresh clone.
- [x] Initial published revision passes hosted CI.
- [ ] Final recovery changes pass hosted CI.

## 5. A usable public Mac release

- [ ] Validate from a clean user/Mac without developer model or build caches; no account required.
- [ ] Verify all required user flows against the exact app/ZIP being released and record test platform/device evidence.
- [ ] Developer ID sign with hardened runtime, notarize, staple and verify Gatekeeper using authorized Apple credentials.
- [ ] Publish tested app ZIP, checksum, source tag, supported platforms and honest limitations; keep development builds marked as previews.
- [ ] Recheck protected project source hashes and confirm no original app/archive changes.

## Evidence log

- Model worker: 17 isolated Swift 6 fixture tests passed, including streaming transport, integrity, retry, cancellation, rollback, packaged-resource lookup and multiple shutdown waiters. No actual weights downloaded by those tests.
- Capture worker: focused invariants and controller typechecking passed; final integrated count and hardware evidence pending.
- Fresh local-source build/test with network denied: **45 tests passed**, zero failures. The optional upstream NeMo binary is excluded. The initial nested SwiftPM sandbox attempt failed to apply; the successful run used an outer deny-network profile and disabled only SwiftPM's nested manifest sandbox.
- All **653 frozen dependency files** also matched the official GitHub archive of the declared revision.
- Packaged helper transcribed generated 13-second English speech with network and all `.build` reads denied. Words matched the intended sample; this is a functional smoke test, not an ASR accuracy benchmark.
- Packaged UI verified model download/activation, import, original/copy SHA-256 equality, automatic local transcript, timestamp jump/playback, title edit and local text export. Test data was generated and stored separately from existing archives.
- An initial developer override under Documents waited in an OS directory-open call; temporary-folder validation succeeded. Folder loading is now visible and Settings remains available for choosing a folder. Permission keys explain user-selected protected folders. Folder permission allow/deny still requires explicit integration verification.
- Developer ID identity was absent from this machine at the initial distribution check; ad hoc development signing is available.

- Public repository: https://github.com/Rafaelhajjar/local-audio. Initial published revision `77ebed9`. Fresh public-clone source check passed all690 files/653 dependency hashes; fresh build/tests with network denied passed45 tests.
- Real app model repair cancellation preserved Ready state and selection. A one-byte alteration in a disposable copied joint graph was rejected on relaunch; explicit repair reused verified staging files, downloaded the remainder, loaded Core ML and activated a new valid pack. The original downloaded test pack and existing user caches were untouched.
- Stop-before-permission completes in the packaged UI. Real microphone validation awaits the human macOS permission choice; the computer-use tool blocks the system permission app. Automatic transcription is disabled in the isolated hardware-test state.

- The current packaged UI recovered a persisted failed job after the generated audio and both sidecars were renamed. Retry used the new path, preserved original bytes and cleared the work list after success. Failed jobs now have a direct Retry action and an accurate needs-attention summary.
- A generated910.109-second WAV completed with network/developer-cache reads denied. All70 expected repeated phrases were present, final timestamp910.08s. See VALIDATION.md for timing/memory context and limits.
- Initial hosted CI passed: https://github.com/Rafaelhajjar/local-audio/actions/runs/39058212907. This does not establish hardware, clean-user or notarization gates.
