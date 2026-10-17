# Validation evidence

LocalAudio 0.1.0 development preview, checked on 2026-10-17. These checks establish the observed behavior below; they do not establish universal microphone compatibility, transcription accuracy or public Gatekeeper installation.

## Build and source

Local platform: Apple M4 Pro, macOS 15.6.1, Apple Swift 6.1.2. Root targets compile checked-in Swift/C/C++ source and Apple SDKs. The optional NeMo binary engine is excluded.

- All 653 frozen FluidAudio source files matched the official GitHub archive for revision `9dfb81b9535e119f855f9ec9c98308ea6076cc95`.
- Source checks passed before public publication. No weights, recordings, transcripts, app state, credentials, logs or build products were committed.
- A fresh public clone passed source checks and all **45 tests** while network access was denied. An outer test sandbox disabled networking; SwiftPM's nested manifest sandbox was disabled to avoid nesting restrictions.
- [Hosted CI on the initial published source](https://github.com/Rafaelhajjar/local-audio/actions/runs/39058212907) passed source checks, all tests, Apple silicon app packaging and artifact upload. [Recovery-source CI](https://github.com/Rafaelhajjar/local-audio/actions/runs/39059122498) and [app-state/packaging CI](https://github.com/Rafaelhajjar/local-audio/actions/runs/39060363575) also passed with the earlier 45-test suite.
- [Native-writer CI](https://github.com/Rafaelhajjar/local-audio/actions/runs/39061835600) passed on `d935a71`, including all **52 tests**, source checks, app packaging and artifact upload. Subsequent evidence-only documentation changes do not alter that code.
- The packaged app contains its helper, model manifest, resource bundles, icon, microphone/folder usage descriptions and licenses. Its local ad hoc signature passed strict verification. ZIP checksums use portable basenames.

The current local suite passes **52 tests** with networking denied. It covers capture frame/rate integrity and completion races, the production native CAF writer, model transport/integrity/retry/cancellation/rollback, packaged resource lookup, recognized graph compatibility, vocabulary extensions, copy preservation, duplicate identities, metadata/queue persistence, and worker cancellation/timeouts. It does not open a microphone or download weights.

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
