# English model setup

LocalAudio has one English transcription pack: Parakeet TDT 0.6B v2, converted to Core ML by FluidInference from NVIDIA's model. Model setup is separate from inference. Only an explicit `ModelManager.install()` call can contact the network; construction, refresh, local-folder selection, recording and inference must remain offline.

## Pinned pack and attribution

The bundled `Sources/LocalAudioCore/Resources/parakeet-v2.json` pins `FluidInference/parakeet-tdt-0.6b-v2-coreml` revision `ee09c569f73759e6d44c9bd16766f477b2b36d39`. It lists **22 files, totaling 464,414,912 bytes**: every published file in the four required compiled bundles, the vocabulary, and the model card. It omits alternative encoders, alternative preprocessing models and unrelated repository files.

Every source URL contains the immutable commit. File sizes and LFS SHA-256 values come from the [Hugging Face tree API at that commit](https://huggingface.co/api/models/FluidInference/parakeet-tdt-0.6b-v2-coreml/tree/ee09c569f73759e6d44c9bd16766f477b2b36d39?recursive=true&expand=false). Small non-LFS files use the API's Git object ID, verified as SHA-1 of `blob <byte-count>\0` followed by the actual bytes. This is deliberately different from SHA-1 of the raw bytes. The API returned one complete page without pagination. The manifest records its retrieval date; the app never fetches fresh metadata or follows a moving `main` revision.

The [pinned conversion model card](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml/blob/ee09c569f73759e6d44c9bd16766f477b2b36d39/README.md) identifies **CC-BY-4.0**. [NVIDIA's original model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) also identifies CC-BY-4.0. Attribution: NVIDIA developed Parakeet TDT 0.6B v2; FluidInference produced the Core ML conversion and Swift integration. LocalAudio installs the selected compiled files without changing their contents. The selected upstream revision contains no separate LICENSE file; the downloaded, integrity-checked README preserves the upstream model card, and the manifest includes the [license link](https://creativecommons.org/licenses/by/4.0/) and attribution. The app's notices should expose this credit, source and license link and describe any future changes. Model licensing is distinct from the application and FluidAudio software licenses.

Only public repository metadata and model cards were fetched while preparing the manifest. No model weights were downloaded by that authoring step.

## Public UI integration API

`ModelManager` is `@MainActor` and conforms to `ObservableObject`:

```swift
let manager = ModelManager(storageDirectory: appOwnedModelStorage) { folder in
    // Coordinator-provided bundled worker: --validate-model <folder>.
    // It must load the selected v2 Core ML models entirely offline,
    // propagate failure, and support cancellation of its child process.
    try await validateUsingBundledWorker(folder)
}
```

Published read-only properties are `statusText: String`, `progress: Double?`, `isBusy: Bool`, `modelDirectory: URL?`, and `isReady: Bool`.

- `await manager.refresh()` checks the locally persisted selection, verifies managed files, and runs the supplied offline validator. Call it once when the app launches. It never downloads or repairs anything.
- `await manager.install()` is the explicit download/Retry action. It publishes failures and keeps the previous ready model usable when setup fails or is cancelled.
- `manager.cancel()` cancels the active task. `isBusy` remains true until work acknowledges cancellation and cleanup completes. The supplied validator must cooperate with cancellation.
- `await manager.cancelAndWait()` is the app-shutdown barrier: cancel setup, await its validator/download completion, and return only after setup state cleanup. Multiple callers can wait on the same operation; an idle call completes immediately. Use this before terminating the application.
- `try await manager.useLocalFolder(folder)` checks the existing folder's required structure and invokes the same offline validator. It stores the selection only after success and never modifies, imports, repairs or downloads into that folder.

Only begin transcription when `isReady` is true and use `modelDirectory` explicitly. Construction does no network activity and does not assume that a saved folder is ready. Disallow concurrent setup controls while `isBusy` is true; a second operation fails rather than competing with the current one. Recorded audio remains independent from setup.

## Installation, retry and activation

The installer uses an ephemeral URLSession download task, with no cookies, credential store or disk URL cache. Files stream to disk rather than accumulating an entire model in `Data`. HTTPS redirects to signed CDN URLs are permitted; per-file hashes remain the byte-integrity boundary. Requests have a 60-second inactivity timeout and a one-hour resource timeout. Each file has at most three attempts with bounded delays. A cancellation or unexpected oversized transfer cancels the task. No metadata polling, background session or automatic update check exists.

Downloads are sequential. Setup first checks any existing staging files by actual size and streamed hash. Verified files are reused on Retry; an interrupted current file restarts from the beginning. This implementation resumes at verified-file boundaries, rather than using HTTP Range or persisting opaque URLSession resume data.

Storage preflight checks the destination filesystem and temporary-download filesystem. The destination reserve covers outstanding files, the largest outstanding file and 128 MiB of headroom; the temporary filesystem also requires the largest file plus headroom. Old installations are retained. This conservative reserve accounts for moving a URLSession temporary file across filesystems and does not promise that other applications will leave the checked space available. A later write failure remains an error.

All manifest relative paths reject traversal, empty components, backslashes and ambiguous escaped characters. Managed staging paths reject symlinks and blocking files. A revision ownership marker identifies the app's staging directory. File integrity is checked on disk in 1 MiB chunks; LFS files use SHA-256 and small Git files use Git blob SHA-1. The full expected pack is rechecked after download, then the supplied offline Core ML validator must succeed.

Activation moves the complete stage to a uniquely named `installed/parakeet-v2-<revision>-<UUID>/` directory and atomically writes the small `model-selection.json` pointer. Until that pointer is successfully persisted, the previous selection remains authoritative. No prior install or externally selected folder is deleted. If pointer persistence fails after moving a completed pack, that unselected pack remains for diagnosis; it is not reported ready. Old-pack cleanup and model removal are intentionally outside this first simple installer.

On restart, `refresh()` validates the selected local folder without contacting the server. Managed packs are checked against the bundled manifest; an external selected folder is checked structurally and loaded by the validator, without claiming that it matches the pinned download's hashes. Missing/corrupt assets fail clearly and require an explicit setup action.

## Required local structure

Select the directory containing `Preprocessor.mlmodelc`, `Encoder.mlmodelc`, `Decoder.mlmodelc`, `JointDecision.mlmodelc`, and `parakeet_vocab.json`. Each bundle needs a nonempty `coremldata.bin`, and unfinished `.partial` files are rejected. The supplied worker validates actual Core ML loadability, vocabulary and the recognized joint graph; directory checks alone never establish readiness.

`ParakeetCompatibility.validateV2Joint(in:)` verifies `JointDecision.mlmodelc/model.mil` against the expected bundled-manifest entry: 9,722 bytes, Git blob SHA-1 `339c35b303b074de7fe047bb099311a4cc08cf53`. This intentionally supports the recognized pinned graph rather than guessing compatibility with arbitrary v2/v3 conversions. The pinned graph has 1,025 token classes and five duration classes; the upstream vocabulary JSON includes additional entries, so vocabulary length alone is not a reliable model-version check. A locally chosen folder must contain the recognized graph; the remaining local files still undergo structural/Core ML validation without claiming they all match the download manifest's hashes. The helper calls this compatibility check before loading models, entirely offline. A mismatch produces an actionable error and never changes the selected folder.

## Validation and remaining evidence

`ModelInstallerTests` use tiny generated files, scripted downloaders and isolated temporary storage. They test actual SHA/Git blob integrity, unsafe paths, disk preflight, failed validation, preservation of the previous selection, retry reuse, cancellation, local-only restoration, and missing local assets. No test automatically contacts Hugging Face or loads real speech weights.

The coordinator must separately exercise the real user-initiated download, offline Core ML loading on the target Mac, denied-network inference, cancellation of the actual child validator, and UI/relaunch behavior before claiming those runtime gates. The manifest authenticates file bytes against pinned upstream metadata carried inside the application; release signing and the integrity of the application bundle remain part of distribution security.

Hashing runs on the installer's actor rather than the main actor and checks cancellation after each 1 MiB read. A stalled filesystem read itself cannot be interrupted by this cooperative check. URLSession task cancellation interrupts an active transfer. An externally supplied validator must acknowledge cancellation and terminate/wait for its child worker; ModelManager cannot forcibly interrupt an arbitrary async closure. `cancelAndWait()` deliberately continues waiting for such a closure rather than claiming the worker has stopped. The bundled worker wrapper supplies its own termination escalation and timeout.

Packaged apps resolve the manifest from the standard `Contents/Resources/LocalAudio_LocalAudioCore.bundle` location before consulting SwiftPM's development resource accessor. The recognized `Contents/Helpers/local-audio-transcriber` executable also probes its sibling `../Resources/LocalAudio_LocalAudioCore.bundle` first. Tests/development can still use `Bundle.module`; a packaged resource does not depend on an absolute build-machine path.

## Optional speaker pack

The same installer also supports `ModelPack.speakers`; transcription remains the default for existing callers. Speaker storage and its selection pointer are separate (`SpeakerModels/`) from English transcription (`Models/`). The speaker manifest pins `speakers-community-1` at `FluidInference/speaker-diarization-coreml@7eab74f3463c736418d0eb10296261ae581146c9`: **26 files / 21,641,906 bytes**. It selects Segmentation, FBank, Embedding and PldaRho compiled bundles, `plda-parameters.json`, and five attribution/provenance files. Unrelated legacy models are rejected by the strict manifest asset allowlist.

The pinned [NOTICE.md](https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/7eab74f3463c736418d0eb10296261ae581146c9/NOTICE.md) scopes CC-BY-4.0 to the selected Community-1 assets and requests credit to pyannote, WeSpeaker, BUT Speech@FIT and FluidInference for the modified Core ML conversions. The downloaded pack retains the README citations, LICENSE, NOTICE.md, PROVENANCE.md and provenance.json. LocalAudio downloads the files unchanged. This is not a blanket license claim for every artifact in that mixed-scope repository. Historical lineage is publisher-reconstructed, not fully build-attested.

`SpeakerModelCompatibility.validate(in:)` checks all 21 runtime asset hashes, including weights and PLDA parameters, for downloaded and external folders. Managed downloads additionally verify all five attribution files. `local-audio-speakers --validate-model` manually loads the four models and exercises native tensor I/O offline. A fixed revision-qualified model ID keeps stored profile embeddings comparable; alternate weights cannot masquerade as that identity. The helper resolves its packaged manifest beside `../Resources`, without requiring developer caches.

See [VOICES.md](VOICES.md) for naming, matching, confirmation, abstention and private storage behavior. Fixture tests do not establish recognition accuracy; actual model loading and generated-audio inference require separate isolated runtime evidence.
