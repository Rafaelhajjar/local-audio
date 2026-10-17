# LocalAudio development

Build one clean native Mac app for standard microphone recording, imported audio, local transcription, playback and text export. Private data and inference stay on the computer. Explicit model setup is the app's only network operation. No accounts, cloud backend, uploads, telemetry, automatic network checks, database or plugin/agent runtime.

Keep storage understandable: original audio in a recording folder, JSON/text sidecars, plus small private settings and work-list files. Preserve originals, report capture and processing failures accurately, keep Stop intentional, and resume unfinished transcription simply. Never add recordings, model weights, personal metadata, logs, credentials or user caches to Git. Do not modify installed applications or existing user archives while developing or testing.

The frozen vendor source must remain unchanged. Check its file hashes and retain licenses. Root targets compile the checked-in Swift/C/C++ sources without the optional NeMo binary engine. No package download is needed to build.

When parallel agent work is requested, use one coordinator and at most two workers with explicit disjoint file ownership. The coordinator owns shared build wiring, integration, commits, public GitHub actions and release checks. Workers return changed paths, verification evidence and remaining limits. Use separate scratch directories; do not compete for a SwiftPM build directory.

Pure tests use generated fixtures. Real microphone, model downloads and application launches need a deliberate isolated integration test assignment. Do not treat pure tests as proof of hardware compatibility, actual inference, clean-machine installation, signing or notarization. Keep supported-platform and device claims aligned with observed evidence.
