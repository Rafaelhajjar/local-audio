# Installation, capture and first-use release gates

Use the exact app in the candidate ZIP/DMG. Test with separate state and recording
folders; never use an existing recording archive for destructive failure tests.
A passing unit suite does not close hardware or clean-Mac gates.

## Safe isolated launch

```sh
open -n dist/LocalAudio.app --args \
  --data-folder "$PWD/work/test-state" \
  --recordings-folder "$PWD/work/test-recordings"
```

Start recordings only after the tester is ready. Keep audio local and obtain
consent from anyone recorded. The sample in Quick start remains in the library.
Do not upload test audio or transcripts to GitHub issues or CI.

## First use

- Empty state: welcome appears once; Set up later leaves recording available.
- Existing settings: microphone, recording folder and transcription choice survive.
- Existing populated library: do not force the welcome screen. Quick start can be reopened.
- Connect the microphone you intend to use. Confirm the detected list updates on attach/detach.
- Select that microphone explicitly. Record ten seconds of speech; Stop & Save.
- Verify the displayed input name and listen back for volume, clarity and channel problems.
- A quiet input must show a hint, still save valid silence, and never claim speech was detected.
- Deny permission: provide the next action, create no completed recording, and permit retry after approval.
- Optional English setup: explicit download only; progress, cancellation, retry and local readiness.
- Skip model setup: finish with a usable recorder. No download should start automatically.
- Transcribe a sample: show queued/running/failed/ready states accurately. Silence may produce no speech.
- Quit/relaunch: preserve setup completion and the test recording; keep unfinished transcription queued.
- Check keyboard navigation, VoiceOver labels, Reduce Motion and text at the minimum window size.

## Capture matrix

For each microphone class you intend to claim, record device name/model, macOS,
app version/build, exact artifact SHA-256, duration, stop trigger and result.
Decode the entire saved file locally:

```sh
swift scripts/inspect-audio.swift '/path/to/saved.caf'
```

| Scenario | Required observation |
| --- | --- |
| Built-in speech, explicit selection | Full decode, audible speech, expected channel/rate, playback |
| System default | Display the resolved device; verify audible input rather than only valid silence |
| USB/DJI/interface speech | Device appears; explicit selection; clear speech; expected channels/rate |
| Bluetooth speech | Pair/connect first, select, record and listen; note profile/channel/rate |
| Disconnect chosen input | Stop, preserve valid prefix or report staging path; never silently switch |
| No buffers / interrupted stream | Bounded failure with a useful next action; no false completed recording |
| Sleep/wake during capture | Stop with a warning; verify saved prefix after wake; no automatic restart |
| Quit during capture | Wait for save; reopen and fully decode the file; metadata persists |
| Low space before Start | Refuse with clear free-space guidance; no completed file |
| Space becomes low during capture | Stop and attempt to save the prefix; surface a warning |
| Stalled or disconnected disk | Stop deadline remains bounded; original staging data is retained if present |
| 30/60/120-minute speech sessions | Full decode; no unexplained gaps; usable playback; UI stays responsive |
| Interrupted file on relaunch | Library shows preserved file(s); Show in Finder; never silently repairs/deletes |

For disk-pressure tests, use a small disposable mounted disk image. Never fill
the Mac's system disk. Capacity is polled every five seconds with a 32 MiB
reserve, so this is a best-effort early stop, not a guarantee against sudden disk
failure. Silence detection never controls recording or saving.

## Clean-Mac distribution

1. Developer ID sign the app and both helpers with hardened runtime and a secure timestamp.
2. Notarize and staple the app, then create, sign, notarize and staple the DMG.
3. Verify strict signatures, both tickets and Gatekeeper acceptance.
4. Download the final artifact through a browser on a separate, clean Mac/user.
   Preserve quarantine. Drag to Applications and launch normally.
5. With no developer caches, exercise permission, first recording, model setup,
   offline transcription, playback, export, quit/relaunch and an upgrade.
6. Record the exact hashes and observations. Never close this gate based only
   on a successful build, notarization, local launch or hdiutil mount.

## Current candidate

The November 24 candidate is still a development build until signing and the
remaining hardware/clean-Mac gates are recorded in VALIDATION.md. Newly added
handling is not a hardware compatibility claim. Do not distribute it as a
production release solely because the scripts pass.
