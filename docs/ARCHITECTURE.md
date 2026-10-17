# Architecture

One SwiftUI Mac application, bundled offline transcription and speaker helpers, ordinary files. The UI records and plays audio without loading speech models into its process. Transcription, speaker analysis and model-load validation run in helpers so expensive work can be cancelled and a model failure does not take down recording.

## Boundaries

- `LocalAudioApp`: SwiftUI views, input capture, playback, settings, sequential work queue and child-process lifecycle. Native file panels and folders keep the interface familiar.
- `LocalAudioCore`: recording metadata/import integrity, queue records, capture invariants and explicit model installation. Model installation is the sole network entrypoint.
- `LocalAudioTranscriber`: manually opens four local Core ML bundles and a vocabulary, sets FluidAudio offline mode before SDK use, runs recognition and atomically writes a transcript sidecar. It never invokes SDK model download or repair paths.
- `LocalAudioSpeakers`: verifies the pinned speaker assets, manually loads local Core ML models and runs anonymous diarization plus clean clip embeddings. It never emits names or downloads models.
- `VoiceLibrary`: an actor owns the private atomic profile/confirmation store. Confirmations bind exact audio hashes, model identities and reviewed analysis/turn snapshots. Recognition returns separate review suggestions; every identity and enrolled example requires a human confirmation. See VOICES.md.
- `vendor/FluidAudio`: frozen upstream dependency, retained licenses and file-hash manifest. Application code does not modify it. Root SwiftPM targets compile these local sources with the optional NeMo binary engine omitted; the selected ASR path does not use it. No external package download is needed.

## Files and failure behavior

Recording writes a unique hidden staging CAF. A successful stop finalizes it, reopens it, checks rate/frame count, then publishes the readable filename. Silence is valid audio. Disconnect, writer, permission and disk failures surface in the UI. Audio never silently changes to a different named microphone during a recording.

Import validates the source, streams its SHA-256, copies to staging, checks source size/date and copied hash, then publishes a UUID filename and metadata. Duplicate imports return the existing content-identical item. Title/date edits only change metadata. Distinct audio extensions retain distinct sidecars. Unreadable library files are listed as warnings without rewriting them.

The queue persists `queued`, `running` or `failed` records. On launch, interrupted `running` entries become `queued`. Work waits for explicit model setup. A child failure leaves audio and prior transcript intact; failed jobs require Retry. Pause/quit terminates the helper and returns the current job to queued. Workers have time limits and SIGKILL escalation after graceful termination. Child output uses a private file to avoid pipe deadlock, and the temporary log is removed afterward. Each invocation receives its own mode-0700 TMPDIR; decoded derivatives are removed after child exit, including cancellation.

Models download sequentially to app-owned staging, with bounded retry and chunked integrity checks. Verified files are reusable. The complete pack must load locally before the model-selection pointer changes. Previous installs and externally selected models remain untouched. See MODELS.md for exact guarantees and limits.

Settings/jobs unreadable as JSON are preserved and reported; the app avoids overwriting the unreadable state. Originals and sidecars are independent of app state. Files are private to the user by default; this is not an encrypted archive. OS backups, sync folders or third-party tools follow the user's own configuration.

## Deliberate limits

Initial target: Apple silicon and macOS 15+, English ASR, one selected microphone input at a time. No system-loopback capture, synchronization service, account, automatic updater, plugin framework, speech-based auto-stop, automatic identity assignment or agent runtime. Voice suggestions remain experimental and Unknown until confirmed. Supported inputs are those macOS exposes through AVFoundation; hardware compatibility must be validated separately from pure tests.
