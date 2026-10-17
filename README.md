# LocalAudio

A small native Mac app for recording, listening and turning audio into text locally.

Choose a microphone, press Record, and stop when you are finished. Or import an existing audio file. Install the optional English model in Settings once, then transcribe without an internet connection. No account, server, telemetry or audio upload.

**Development preview.** Apple silicon, macOS 15 or newer. The app is being validated; a Developer ID signed and notarized public installer is not available yet. Build from source below. See [the release checklist](docs/CHECKLIST.md) for evidence and remaining work.

## What it does

- Records the system default microphone or a selected input exposed by macOS: built-in, USB, audio interface or compatible Bluetooth device. Device quality and driver behavior vary; system audio capture is outside this version.
- Saves original PCM CAF recordings. Import copies support WAV, CAF, M4A, MP3, AIFF, FLAC and AAC when macOS can decode the particular file.
- Plays audio with seeking, speed controls and transcript timestamps that jump to the corresponding audio. Recording dates are editable; displayed transcript times use the recording's time of day.
- Installs a pinned, integrity-checked English Parakeet v2 model, or reads a compatible existing model folder without changing it. About 464 MB of model files plus temporary space are required.
- Keeps a small persistent transcription queue, preserves original audio and earlier transcripts on failure, and exports readable text.

English transcription is automatic speech recognition, not a guaranteed verbatim record. This version does not identify speakers, train voice profiles or summarize conversations. Recording works without model setup.

## Build and run

Install Xcode with the Swift 6 toolchain and command-line tools. Then:

```sh
git clone https://github.com/Rafaelhajjar/local-audio.git
cd local-audio
swift test --scratch-path .build/app
./scripts/build-app.sh
open dist/LocalAudio.app
```

The build uses checked-in source and Apple SDKs. The optional upstream NeMo binary engine is excluded; no package or model download is needed to build. The app only uses the network after an explicit model download action. The default build uses an ad hoc local signature and produces an app plus ZIP in `dist/`. It is intended for local development, not a notarized public installer.

For an isolated test launch that keeps your normal app data separate:

```sh
dist/LocalAudio.app/Contents/MacOS/LocalAudio \
  --data-folder /tmp/LocalAudio-test-state \
  --recordings-folder /tmp/LocalAudio-test-recordings
```

## Your files

The default recording location is `~/Music/LocalAudio Recordings`; choose another folder in Settings. Imported files are copied, leaving their source unchanged. Titles and dates live in `<audio filename>.localaudio.json`; transcripts live in `<audio filename>.transcript.json`. You can open the folder in Finder. There is no database.

Private settings, unfinished work and installed models live in `~/Library/Application Support/LocalAudio`. Quitting stops and saves recording, cancels active transcription/model setup and retains unfinished transcription jobs for the next launch. Interrupted capture files use a hidden `.recording-*.incomplete.caf` name; a failure reports the recovery path rather than claiming they are complete.

Model setup downloads public files from Hugging Face and its CDN. After setup, recording, library browsing, playback and transcription use local files. External model selection does not copy or repair that folder. Removing the application does not remove your recordings or installed models.

## Contributing and releases

[Architecture](docs/ARCHITECTURE.md) · [Model setup](docs/MODELS.md) · [Validation](docs/VALIDATION.md) · [Release procedure](docs/RELEASE.md) · [Checklist](docs/CHECKLIST.md)

Use generated or consented audio for tests. Never commit recordings, model weights, personal metadata, logs or credentials. Small changes should preserve the straightforward folder-and-sidecar design. Open an issue with macOS/app version, device type and reproducible steps; sharing private recordings is optional.

Application code: [MIT](LICENSE). FluidAudio: Apache-2.0. The optional Parakeet model: CC-BY-4.0. See [attribution and licenses](THIRD_PARTY_NOTICES.md).
