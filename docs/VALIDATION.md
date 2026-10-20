# Validation evidence

LocalAudio development previews, checked through 2026-10-20. Earlier preview evidence is retained; the 0.2.1 integration and release review are recorded separately below. These checks establish the observed behavior below; they do not establish universal microphone compatibility, transcription accuracy or public Gatekeeper installation.

## Build and source

Local platform: Apple M4 Pro, macOS 15.6.1, Apple Swift 6.1.2. Root targets compile checked-in Swift/C/C++ source and Apple SDKs. The optional NeMo binary engine is excluded.

- All 653 frozen FluidAudio source files matched the official GitHub archive for revision `9dfb81b9535e119f855f9ec9c98308ea6076cc95`.
- Source checks passed before public publication. No weights, recordings, transcripts, app state, credentials, logs or build products were committed.
- A fresh public clone passed source checks and all **45 tests** while network access was denied. An outer test sandbox disabled networking; SwiftPM's nested manifest sandbox was disabled to avoid nesting restrictions.
- [Hosted CI on the initial published source](https://github.com/Rafaelhajjar/local-audio/actions/runs/39058212907) passed source checks, all tests, Apple silicon app packaging and artifact upload. [Recovery-source CI](https://github.com/Rafaelhajjar/local-audio/actions/runs/39059122498) and [app-state/packaging CI](https://github.com/Rafaelhajjar/local-audio/actions/runs/39060363575) also passed with the earlier 45-test suite.
- [Native-writer CI](https://github.com/Rafaelhajjar/local-audio/actions/runs/39061835600) passed on `d935a71`, including all **52 tests**, source checks, app packaging and artifact upload. Subsequent evidence-only documentation changes do not alter that code.
- The packaged app contains its helper, model manifest, resource bundles, icon, microphone/folder usage descriptions and licenses. Its local ad hoc signature passed strict verification. ZIP checksums use portable basenames.

The earlier 0.1 local suite passed **52 tests** with networking denied. It covers capture frame/rate integrity and completion races, the production native CAF writer, model transport/integrity/retry/cancellation/rollback, packaged resource lookup, recognized graph compatibility, vocabulary extensions, copy preservation, duplicate identities, metadata/queue persistence, and worker cancellation/timeouts. It does not open a microphone or download weights.

## Native audio-file writing

Seven generated-audio tests use the same `PCMRecordingWriter` as microphone capture, through actual `AVAssetWriter` appends, finalization, `AVAudioFile` reopening and publication. Generated buffers start at a nonzero timestamp and are paced at their represented cadence. Saved 48 kHz stereo and 16 kHz mono CAF files preserve every decoded Int16 sample, channel position, frame count and sample rate without inserting a timestamp prefix. Silence also saves correctly.

Empty input publishes nothing. A format change rejects the new buffer while retaining the valid prefix. A previously claimed completion gate permits finalization but suppresses publication. An existing destination is never replaced; the completed staging file remains readable for recovery. These tests exercise native filesystem and codec behavior without capture sessions, device enumeration, microphone access, private audio or model loading. Physical evidence is separate below.

## Packaged microphone capture

After the owner approved macOS microphone access, the exact ad hoc app in the preview ZIP was tested on the Mac above. ZIP SHA-256: `59a59bac991c98a1d3124e9603c8a2af2066ee73463742819cad1891c7cc68b4`. Tests used isolated state/recording folders with automatic transcription disabled; microphone audio stayed local and was not committed or uploaded.

| Physical check | Saved result |
| --- | --- |
| Explicit MacBook Pro microphone, Stop & Save | 44.1 kHz mono; 347,136 frames; 7.8716 seconds; nonzero decoded PCM |
| Quit during built-in recording | 44.1 kHz mono; 215,040 frames; 4.8762 seconds; readable CAF and metadata after process exit |
| System default, resolving to connected AirPods Pro | 24 kHz mono; 204,960 frames; 8.54 seconds; all-zero PCM saved as valid silence |

The built-in test showed Recording only after successful audio appends, a positive-size hidden staging file during capture, and Ready after Stop & Save. The saved file reopened and decoded fully; UI playback advanced normally. Quit saved the active recording and metadata before exit. Relaunch restored the recordings, system-default selection and local model readiness. No incomplete recording or pending transcription job remained, and the isolated test app was closed after verification.

The AirPods result verifies the default-input path, valid PCM delivery, silence handling and finalization. It does not establish Bluetooth speech capture quality. USB/interface capture, Bluetooth speech, unplug/sleep, permission denial and sustained disk-pressure behavior remain unverified.

## Real model and generated audio

An explicit Settings action downloaded the pinned **22-file / 464,414,912-byte** model pack into isolated app storage. Every file passed its manifest check and the helper loaded Core ML before activation. Setup cancellation retained the working selection. A one-byte corruption in a disposable copied joint graph was rejected on relaunch; an explicit repair reused verified staging files, downloaded the remainder and activated a new valid pack. Existing user caches were untouched.

The packaged helper recognized the intended words in a generated 13-second English sample with both networking and all developer `.build` reads denied. This also checked that packaged resources are used instead of a development-path fallback.

A second generated WAV repeated that sample 70 times to exercise the disk-backed path:

| Observation | Result |
| --- | --- |
| Audio duration | 910.109 seconds |
| Expected / recognized repeated phrase | 70 / 70 |
| Final segment end | 910.08 seconds |
| Transcript segments | 92 |
| Measured wall time | 2.19 seconds |
| Helper maximum resident set size | 196,558,848 bytes |
| Network and developer build reads | Denied |

This was repeated synthetic speech with warm system caches on one Mac. Process RSS excludes allocations in Core ML/neural-engine services and is not a total-system memory measurement. These numbers are a functional stress check, not general speed, memory or accuracy promises.

## Packaged interface and recovery

Verified through the native app:

- Import a generated AIFF, preserve source/copy SHA-256 equality, create a local transcript and display recording time-of-day timestamps.
- Play audio, jump from the second transcript timestamp, and observe matching playback position.
- Change a title, edit/save/restore the recording date through the native picker, and export readable text locally; preserve the audio bytes.
- Relaunch with saved library/model state. Detect a missing audio file as a failed job without replacing its previous transcript.
- Restore the audio and its sidecars under a different filename, retain the recording identity, Retry using the current path, and clear the job after success.
- Stop while microphone permission is pending, return to Ready, and avoid creating a false completed recording. The native Recording menu disables Start and enables Stop during this state, and its Stop action works. Settings also disables the recording-folder chooser while capture is starting and re-enables it after Stop.

An early developer override into Documents waited inside an OS directory-open call. Temporary-folder validation succeeded. Folder loading is now visible and Settings remains available to choose a folder. Native chooser selection and direct startup access have different permission behavior; see [Apple's folder-access documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsdocumentsfolderusagedescription). Protected-folder permission allow/deny remains a separate manual check.

## Deferred production validation

- Packaged permission denial, missing-buffer failures, USB/interface capture and broader Bluetooth speech behavior; unplug/sleep and sustained disk-pressure checks. The limited AirPods silence result above does not prove these cases.
- A clean user/Mac installation without developer caches and a broader set of real, consented audio. Synthetic samples cannot establish real-world ASR quality.
- Developer ID signing, notarization, stapling and Gatekeeper assessment. No valid signing identity was installed during this run. The owner explicitly chose development-preview scope; the current ZIP is ad hoc signed and unnotarized, and a downloaded copy may be blocked by macOS.

## Local voice profiles (0.2 preview)

The optional 26-file, 21,641,906-byte Community-1 speaker pack was downloaded explicitly in the packaged app into isolated state. Activation passed pinned integrity checks, actual Core ML loading and native tensor-I/O validation. No existing user cache, recording archive or voice profile was used.

Two different generated phrases from the installed macOS Samantha voice were imported through the UI. Source/copy SHA-256 hashes matched and the two phrases had different audio hashes. Name This Voice created Synthetic A with one confirmed clean example. On the later phrase, the measured embedding cosine was 0.92609: the UI showed **Unknown** and a separate **Possible match: Synthetic A**. Explicit Confirm added its name and a second example. Keep Unknown removed that confirmation/example and restored Unknown while leaving the suggestion separate. Anonymous sidecars contained no person IDs; the private bank used mode 0600.

A generated Daniel-voice control ran through the packaged speaker helper with network and all developer `.build` reads denied. It produced one usable vector with best cosine 0.52147 against Synthetic A, below the review gate. No identity or example was added. A generated 906-second repeated-voice CAF also completed anonymous analysis. These are functional checks, not a diarization or identity-accuracy benchmark; real multi-person, cross-device, cross-day calibration remains open.

Worker scratch was empty after native validation and completed analysis. Fixture tests separately terminate a real child after it writes a decoded derivative and verify the private mode-0700 temporary directory and derivative are removed. A cancellation attempt on the generated long speaker file finished before the UI could cancel, so it is not counted as a native inference cancellation check.

Voice-specific tests also cover atomic local persistence, corrupt/future-version preservation, stripping forged helper names, changed source/model/turn boundaries, no automatic enrollment, duplicate-content exclusion, ambiguous/malformed vectors, stale confirmations, renaming/forgetting, and Unknown-only exports before confirmation. No test downloads models or opens a microphone.

The final 0.2 suite passed **88 tests**, zero failures, both normally and with networking denied. The final packaged app passed strict ad hoc signature checks, profile persistence on relaunch, explicit possible-match confirmation, atomic new-person naming and native reanalysis. The final packaged speaker helper also completed the different-voice control with network and developer build-cache reads denied. Both worker scratch folders were empty after exit; original generated audio hashes remained unchanged. All 725 protected earlier-project source files still matched their baseline, and all 653 frozen dependency hashes matched.

Final tested 0.2 ZIP SHA-256: `89ec74c08310578000275af18c4ad13c6e2e1c5f3f1af350a374767bec15416c`. Model weights and test audio are absent from this ZIP and from source. This remains an ad hoc, unnotarized development preview; clean-Mac/Gatekeeper and real-person matching accuracy are unverified.

## Integrated recognition pipeline (0.2.1 preview)

Checked on 2026-10-18. The current source and local package integrate repeated short-clip input with original-duration pooling, speech-weighted center/start/end excerpts and source-balanced profile prototypes. Extraction recipes remain separate from model identity. The earlier public 0.2.0 release predates this integration.

All **112 Swift tests passed**, including fourteen helper test methods and generated-fixture tests for legacy decoding, recipe isolation, source balancing, copied-window deduplication, preserved human confirmation IDs/dates, unavailable-example recovery, label-only turns, stale refresh rejection, bank-first publication failure and retry, and confirmed-only exports. All 653 frozen vendor file hashes matched. These pure tests require no model downloads or microphone input.

The packaged helper re-extracted 138 previously named turns across twelve source files with network access and writes to the original archive/label/model folders denied. All 113 usable vectors reproduced the selected experiment within a maximum absolute component difference of 1.4e-8. On the same 65 usable cross-day examples and common reference cohort, first-choice agreement was **58/65**, reproducing the development experiment versus the earlier extractor/scorer's 24/65. The full pipeline recovered one additional usable known query: 59/66. All 138 turns remained in full-system denominators. Only two people have cross-day examples; labels were mostly owner-reviewed but individual purity is uncertain, and there is no untouched final set. These are development ranking agreements, not general recognition accuracy.

Current 0.60 similarity and 0.15 margin review gates produced eleven suggested matches agreeing with saved labels and zero observed disagreements on this same development corpus, with 127 abstentions. The gates are development heuristics, not independently validated precision guarantees. Every displayed name and enrolled example still requires explicit human confirmation.

The exact local ZIP was extracted, all three binaries matched the packaged app and its signature verified. With network access denied, the generated-speech UI fixture updated two legacy profiles without changing their names, confirmation records, enrollment IDs/dates, example counts or original audio. Each updated example recorded three contributing windows. Offline transcription then triggered automatic voice refresh without changing the reviewed turn IDs/bounds, confirmations or profile bank. Keep Unknown revoked one generated turn's name; the UI separately offered Possible match while the turn remained Unknown, and explicit Confirm applied the name. An imported different generated voice remained Unknown with no suggestion. These are limited synthetic controls. No installed app or original user library was modified. All fourteen protected original audio/label files retained their hashes. The local package remains ad hoc signed and unnotarized.

Local 0.2.1 ZIP SHA-256: `419b0f662039ac29bf6497511c1e273ab5570b52b05993c7cf66de660197ed19`. No private evaluation data, models, audio, app state or logs are included in source or the ZIP.


## 0.2.1 release review (2026-10-20)

The integrated changes were reviewed before publication. All **112 tests passed again with networking denied**, and the source check passed all 716 source files with all 653 frozen dependency hashes unchanged. The tests use generated fixtures and do not open a microphone or download models.

A fresh Apple silicon release build completed and passed strict ad hoc signature verification. Every file in the rebuilt application matched the extracted October 18 tested application, including all three binaries, resources, manifests and signatures. The release retains that exact previously tested ZIP and its checksum (`419b0f662039ac29bf6497511c1e273ab5570b52b05993c7cf66de660197ed19`); archive timestamps can change a newly generated ZIP without changing its app contents. The ZIP contains no recordings, transcripts, voice profiles, model weights, private evaluation data or logs.

This review does not add new hardware, real-world accuracy, clean-Mac installation or notarization evidence. The release remains an Apple silicon/macOS 15+ development preview with experimental, human-confirmed voice matching.
