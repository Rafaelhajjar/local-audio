# Local voice profiles

Install the optional speaker model in Settings. Open a recording in Library, select Voices and choose Find Voices. Speaker analysis runs in a bundled offline helper and creates anonymous speech turns. Listen before using Name This Voice; choose an existing person or create a new name. Each confirmation applies to that turn only. When usable speech is available, one voice example combines up to three 2–5 second excerpts from that reviewed turn and is added to the person's local profile.

A later recording can show a separate Possible match suggestion from the saved profiles. The turn remains Unknown until the user presses Confirm or names it manually. Weak, ambiguous, short, silent and overlapping examples abstain. Suggestions never change identities or train profiles automatically. The People page supports renaming and forgetting a person; forgetting removes their stored examples and confirmation links while preserving original audio and transcript text. Keep Unknown revokes that turn's confirmation and its enrolled example.

After optional speaker setup, newly completed transcriptions also attempt voice analysis. Existing recordings can be analyzed explicitly, with or without an English transcript. Cancellation leaves earlier analysis and profiles intact; use Find Voices again to retry. This small voice pass does not add another persistent job database.

## Storage and attribution boundaries

- Original audio and `.transcript.json` files are never rewritten by naming.
- `<audio filename>.voices.json` stores anonymous turns, model and extraction-recipe identities, source hash, optional 256D embeddings and the actual contributing excerpt ranges. A helper-provided person identity is discarded.
- `Voices/voice-library.json` inside app data stores profiles, human confirmations and confirmed examples in one atomic private JSON transaction. The directory is created with mode 0700 and files with 0600. No database or service is involved.
- Confirmation overlays require the exact recording ID, source SHA-256, model ID, turn ID and time range. Changed audio or changed analysis cannot silently inherit a name.
- Recognition compares available confirmed examples from the exact same pinned model and extraction recipe only. The current recording ID and byte-identical source hashes are excluded, including copied files; differently encoded copies are not detected as the same audio.
- Current matching averages normalized examples within each source recording, then gives each recording equal weight in the person's normalized prototype. Experimental cosine similarity 0.60 and runner-up margin 0.15 gate review suggestions. These heuristics were selected conservatively from development data; they are not independently calibrated precision guarantees or identity probabilities. Legacy analyses retain their earlier top-two-source scorer and 0.92/0.12 gates until updated. One confirmed usable example can support a later suggestion.
- Transcript chunks containing unknown, mixed or insufficiently covered speakers stay Unknown. Exports use human-confirmed names only, never possible-match suggestions.

A corrupt or newer voice store/sidecar is preserved and reported instead of overwritten. Recording files and a voice library can be backed up locally; moving an audio file requires moving its full-name sidecars too. Renaming a person updates the presentation through its stable ID. Profiles store embeddings and provenance; they do not copy raw sample audio into a second archive.

## Updating saved voices

For recordings analyzed by the earlier preview, use **Library → recording → Voices → Update Voice Matching**. To update older examples already in profiles, use **People → Update Saved Voices** with their originals visible in Library. This reads local audio again using the existing speaker model; it downloads nothing and does not require new labels.

Updating keeps the exact reviewed turn IDs, boundaries, speaker groups and human names. It replaces only measurements for already enrolled examples; label-only confirmations do not become training examples. Missing or changed originals are reported and remain saved. Unusable refreshed examples are excluded from matching and can be retried. Cancellation keeps completed updates and all confirmed names. Each profile update is atomic; the anonymous sidecar is published separately. If publication is interrupted, mismatched recipes cannot score together and retrying repairs the measurement state.

Current analyses and the modified private bank use schema version 2 so older preview apps refuse these files instead of silently mixing incompatible measurements. Keep a local backup before reverting to an older app. Version 1 data is read without discarding its labels.

## Models and processing

The optional 26-file speaker pack is 21,641,906 bytes, pinned to `FluidInference/speaker-diarization-coreml@7eab74f3463c736418d0eb10296261ae581146c9`. It includes four compiled models, PLDA parameters and attribution/provenance files. The selected Community-1 assets have the license scope described in the [pinned NOTICE](https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/7eab74f3463c736418d0eb10296261ae581146c9/NOTICE.md); legacy models are excluded. Credit pyannote, WeSpeaker, BUT Speech@FIT and FluidInference for the modified Core ML conversions. LocalAudio downloads the selected files unchanged. See THIRD_PARTY_NOTICES.md and MODELS.md.

Only explicit model installation downloads files. Startup, local-folder checks, speaker analysis, matching and profile edits are offline. The helper checks every material runtime file against pinned hashes, including FBank and embedding weights, even for externally selected folders. A different model cannot reuse the revision-qualified embedding identity. The publisher's historical provenance is reconstructed, not a fully attested conversion build.

The worker manually loads verified models and sets the SDK offline mode. Current extraction repeats the short excerpt across a ten-second model input while pooling only the original duration. Repetition adds no new voice evidence. The center excerpt is supplemented by start/end excerpts for turns at least eight seconds long; known other-speaker overlap and margins are excluded. A normalized mean weights usable excerpts by estimated dominant solo speech from the segmentation model. Those weights are heuristics, not verified speaker purity. Zero usable speech weight produces no matching vector. Missing or unusable embeddings do not prevent manual labels, but cannot enroll matching examples. The parent gives each helper a private temporary directory and removes decoded derivatives after successful, failed or cancelled child exit. No microphone recording is started by voice analysis.

Voice matching remains experimental. Diarization can group speakers incorrectly, and a high similarity does not prove identity. Human confirmation is required for every name; this feature is not identity verification.
