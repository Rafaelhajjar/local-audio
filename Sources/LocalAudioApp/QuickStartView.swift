import SwiftUI
import AppKit
import LocalAudioCore

/// The walkthrough uses the same capture, playback and model setup paths as
/// everyday use. Nothing records or downloads until the user presses a button.
struct QuickStartView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var capture: CaptureController
    @ObservedObject private var models: ModelManager
    @ObservedObject private var player: PlaybackController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var waitingForTest = false
    @State private var testRecording: AudioRecording?
    @State private var testInputName = ""
    let finished: () -> Void

    private let ink = Color(red: 0.16, green: 0.22, blue: 0.21)
    private let paper = Color(red: 0.98, green: 0.97, blue: 0.94)
    private let titles = ["A little space\nfor your thoughts.", "Let's find\nyour sound.", "Hear it\nfor yourself.", "Your words,\nin writing.", "Make yourself\nat home."]
    private let subtitles = ["Record here. Keep it here.", "A quick microphone check", "Your first recording", "Optional. Entirely on this Mac.", "You're ready to begin."]
    private var busy: Bool { capture.isBusy || waitingForTest }

    init(store: AppStore, finished: @escaping () -> Void) {
        self.store = store; capture = store.capture; models = store.models; player = store.player
        self.finished = finished
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                Label("LocalAudio", systemImage: "waveform").font(.headline)
                Spacer(minLength: 20)
                QuietWave(active: capture.isRecording, level: capture.level)
                    .frame(height: 94).accessibilityHidden(true)
                Text(titles[step]).font(.system(size: 37, weight: .medium, design: .serif)).fixedSize(horizontal: false, vertical: true)
                Text(subtitles[step]).font(.callout).foregroundStyle(ink.opacity(0.7))
                Spacer(minLength: 20)
                Label("No account. No audio upload.", systemImage: "lock.shield").font(.caption)
            }
            .padding(36).frame(width: 330, alignment: .leading)
            .frame(maxHeight: .infinity).background(paper)
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 7) {
                    ForEach(0..<5) { index in
                        Capsule().fill(index <= step ? Color.accentTeal : ink.opacity(0.09)).frame(height: 4)
                    }
                }.accessibilityLabel("Setup step \(step + 1) of 5")
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        content
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
                Spacer(minLength: 0)
                Divider()
                HStack {
                    if step > 0 && step < 4 {
                        Button("Back") { move(to: step - 1) }.buttonStyle(.plain).disabled(busy || models.isBusy)
                    } else {
                        Button(step == 0 ? "Set up later" : "Close setup") { finish() }.buttonStyle(.plain).disabled(busy || models.isBusy)
                    }
                    Spacer()
                    primaryAction
                }
                Text("Microphone access starts only when you record. Ask others before recording a conversation.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(32).frame(width: 450).frame(maxHeight: .infinity).background(.white)
        }
        .foregroundStyle(ink).frame(height: 590).preferredColorScheme(.light)
        .onDisappear { player.pause() }
        .onChange(of: store.lastSavedRecording?.id) { _, _ in
            guard waitingForTest, let item = store.lastSavedRecording else { return }
            testInputName = capture.lastInputName ?? testInputName
            testRecording = item; waitingForTest = false; move(to: 2)
        }
        .onChange(of: capture.isBusy) { _, active in
            if !active, capture.lastSavedURL == nil { waitingForTest = false }
        }
        .onChange(of: store.errorMessage) { _, message in
            if message != nil, !capture.isBusy { waitingForTest = false }
        }
        .onChange(of: capture.selectedDeviceID) { _, _ in store.savePreferences() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0:
            Text("Welcome to your listening space.").font(.title2.weight(.semibold))
            Text("A few moments to check your microphone and try your first recording.").foregroundStyle(.secondary)
            feature("mic", "Record or import", "Use your Mac microphone, a connected mic, or an audio file.")
            feature("doc.text", "Turn audio into text", "Add the optional English model whenever you're ready.")
            feature("folder", "Choose what stays", "Keep transcripts, set an audio limit, and save favorite passages in your vault.")
        case 1:
            Text(busy ? "Say a few words." : "Connect the mic you want to use.").font(.title2.weight(.semibold))
            if busy {
                Text("Speak normally, then choose Stop & Save. Next, you'll listen back to check the sound.").foregroundStyle(.secondary)
                Label(capture.lastInputName ?? capture.selectedInputName, systemImage: "mic").font(.callout.weight(.medium))
            } else {
                captureError
                Text("Plug in your microphone or connect it over Bluetooth, then select it below. This list updates as microphones connect.").foregroundStyle(.secondary)
                Toggle("Allow the built-in Mac microphone", isOn: Binding(get: { store.microphonePolicy.allowMacMicrophone }, set: { value in
                    var policy = store.microphonePolicy; policy.allowMacMicrophone = value
                    if !value && policy.mode == .macAlways { policy.mode = .approved }
                    store.setMicrophonePolicy(policy)
                }))
                InputPicker(capture: capture, policy: store.microphonePolicy)
                Text("For several approved microphones or automatic recording, use Settings → Microphones after setup.").font(.caption).foregroundStyle(.secondary)
                Text("Say a few words, then Stop & Save. Your test stays in your library.").font(.callout).foregroundStyle(.secondary)
            }
            if busy {
            VStack(spacing: 12) {
                Text(clock(capture.elapsed)).font(.system(size: 42, weight: .light, design: .rounded)).monospacedDigit()
                LevelMeter(level: capture.level, active: capture.isRecording).frame(height: 12)
                Text(capture.isFinalizing ? "Saving your sample…" : capture.isStarting ? "Starting microphone…" : capture.isRecording ? (capture.signal.hasAudibleInput ? "Sound detected" : "Listening for input…") : waitingForTest ? "Adding your sample to the library…" : "Your microphone starts when you press Record.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(20).background(paper, in: RoundedRectangle(cornerRadius: 16))
            if let hint = capture.signal.quietInputHint, capture.isRecording { Text(hint).font(.callout).foregroundStyle(.orange) }
            }
            if !busy { Button("Skip the sound check") { move(to: 3) }.buttonStyle(.link) }
        case 2:
            Text("Does that sound like you?").font(.title2.weight(.semibold))
            Text("Listen back to check the volume and clarity. A moving meter shows input; listening tells you whether it's useful.").foregroundStyle(.secondary)
            if let item = testRecording {
                Label(clock(item.duration) + " · Saved in your library", systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentTeal)
                Label(testInputName, systemImage: "mic").font(.callout).foregroundStyle(.secondary)
                Button { player.toggle() } label: {
                    Label(player.isPlaying ? "Pause sample" : "Play my sample", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                }.buttonStyle(.bordered).controlSize(.large)
                if let error = player.error { Text(error).font(.callout).foregroundStyle(.orange) }
                if !capture.signal.hasAudibleInput {
                    Text("The input was very quiet. If you can't hear yourself, try another microphone and record again.").font(.callout).foregroundStyle(.orange)
                }
                Button("Try another recording") { player.pause(); move(to: 1) }.buttonStyle(.link)
            }
            captureError
        case 3:
            Text(models.isReady ? "Transcription is ready." : "Give your audio a transcript.").font(.title2.weight(.semibold))
            Text("The English model downloads once, about 464 MB. After setup, transcription works offline. Your audio is never uploaded.").foregroundStyle(.secondary)
            if models.isReady {
                feature("checkmark.circle", "Ready on this Mac", testRecording == nil ? "Record or import audio to get your first transcript." : "Continue to transcribe your sample locally.")
            } else if models.isBusy {
                if let progress = models.progress { ProgressView(value: progress) } else { ProgressView() }
                Text(models.statusText).font(.callout).textSelection(.enabled)
                Button("Cancel download") { models.cancel() }.buttonStyle(.link)
            } else {
                Button("Download English Model") { Task { await models.install(); store.processNext() } }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(store.isProcessing)
                Text(models.statusText).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Downloads model files from Hugging Face. Recording works without this model.").font(.caption).foregroundStyle(.secondary)
            }
        default:
            Text(testRecording != nil ? "Your first recording, saved." : "Your space is ready.").font(.title2.weight(.semibold))
            if let item = testRecording {
                if let job = store.job(for: item) {
                    if job.status == .failed {
                        Text(job.error ?? "Transcription needs another try. Your original audio is safe.").font(.callout).foregroundStyle(.orange)
                        Button("Try transcription again") { store.enqueue(item) }
                    } else if !models.isReady {
                        feature("checkmark.circle", "Your audio is saved", "Transcription can wait. Set up the English model in Settings whenever you're ready.")
                    } else if store.queuePaused {
                        Text("Transcription is paused. Your audio is saved.").foregroundStyle(.secondary)
                        Button("Resume transcription") { store.resumeQueue() }
                    } else {
                        ProgressView(job.status == .running ? "Transcribing on your Mac…" : "Your sample is queued…")
                        Text("You can open your library while it finishes.").font(.callout).foregroundStyle(.secondary)
                    }
                } else if store.selected?.id == item.id, let transcript = store.transcript {
                    Text(transcript.text.isEmpty ? "No speech was detected. You can record another sample in the library." : transcript.text)
                        .font(.body).textSelection(.enabled).padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(paper, in: RoundedRectangle(cornerRadius: 14))
                    Text("Automatic transcription can make mistakes. Your original audio is always available.").font(.caption).foregroundStyle(.secondary)
                } else {
                    feature("checkmark.circle", "Sample saved", "Find it in your library whenever you need it.")
                }
            }
            feature("folder", "Your recording folder", store.recordingsFolder.path)
            Button("Choose another folder…") { store.chooseFolder() }.buttonStyle(.link).disabled(!store.canChangeFolder)
            Text("You can revisit this walkthrough from the sidebar. Voice profiles are optional and available in People.").font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var primaryAction: some View {
        switch step {
        case 0:
            Button("Let's begin") { move(to: 1) }.buttonStyle(.borderedProminent).controlSize(.large)
        case 1:
            if capture.isStarting || capture.isRecording {
                Button("Stop & Save") { Task { await store.stopRecording() } }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
            } else {
                Button(capture.isFinalizing || waitingForTest ? "Saving…" : "Record a sample") {
                    waitingForTest = true
                    testInputName = capture.selectedInputName
                    Task { await store.startRecording() }
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(capture.isFinalizing || waitingForTest || store.isLibraryLoading)
            }
        case 2:
            Button("Sounds good") { player.pause(); move(to: 3) }.buttonStyle(.borderedProminent).controlSize(.large)
        case 3:
            Button(models.isReady ? (testRecording == nil ? "Continue" : "Transcribe my sample") : "Do this later") {
                if models.isReady, let item = testRecording, store.job(for: item) == nil,
                   !FileManager.default.fileExists(atPath: item.transcriptURL.path) { store.enqueue(item) }
                move(to: 4)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(models.isBusy)
        default:
            Button(testRecording == nil ? "Start recording" : "Open my library") { finish() }.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    @ViewBuilder private var captureError: some View {
        if let error = capture.lastError {
            Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            if capture.microphoneAccessDenied { Button("Open Microphone Settings") { openMicrophoneSettings() }.buttonStyle(.link) }
        }
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.accentTeal).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
    private func move(to next: Int) {
        guard !busy else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { step = next }
    }
    private func finish() {
        guard !busy, !models.isBusy else { return }
        player.pause(); store.finishQuickStart(); finished()
    }
}

struct InputPicker: View {
    @ObservedObject var capture: CaptureController
    var policy: MicrophonePolicy
    private var allowed: [AudioInput] {
        capture.devices.filter { mic in
            (policy.allowMacMicrophone || !mic.isBuiltIn) &&
            (policy.mode != .approved || policy.approved.contains(where: { $0.id == mic.id })) &&
            (policy.mode != .macAlways || mic.isBuiltIn)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CONNECTED MICROPHONES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { capture.refreshInputs() }.buttonStyle(.link).disabled(capture.isBusy)
            }
            ScrollView {
                VStack(spacing: 6) {
                    if policy.mode == .manual, allowed.contains(where: { $0.id == capture.defaultDeviceID }) {
                        inputRow(id: nil, name: "System default", detail: allowed.first { $0.id == capture.defaultDeviceID }?.name)
                    }
                if let selected = capture.selectedDeviceID, !capture.devices.contains(where: { $0.id == selected }) {
                        inputRow(id: selected, name: "Unavailable microphone", detail: "Reconnect it or select another input.")
                    }
                    ForEach(allowed) { input in
                        inputRow(id: input.id, name: input.name, detail: nil)
                    }
                }
            }.frame(maxHeight: 150)
            if allowed.isEmpty {
                Text("Connect an allowed microphone, or review your microphone preferences in Settings.").font(.callout).foregroundStyle(.orange)
            } else {
                Text("Don't see yours? Check its cable, power, or Bluetooth connection, then Refresh.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func inputRow(id: String?, name: String, detail: String?) -> some View {
        Button {
            capture.selectedDeviceID = id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: (policy.mode == .manual ? capture.selectedDeviceID == id : policy.resolve(devices: allowed, selectedID: nil, defaultID: nil)?.id == id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.accentTeal)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.callout.weight(.medium))
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }.padding(10).contentShape(Rectangle())
                .background(capture.selectedDeviceID == id ? Color.accentTeal.opacity(0.08) : Color.gray.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).disabled(capture.isBusy)
            .accessibilityLabel(name + (detail.map { ", " + $0 } ?? "") + (capture.selectedDeviceID == id ? ", selected" : ""))
    }
}

private struct QuietWave: View {
    let active: Bool
    let level: Double
    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(0..<31) { index in
                let envelope = sin(Double(index + 1) / 32 * .pi)
                let detail = 0.35 + 0.65 * abs(sin(Double(index) * 1.73))
                let input = active ? max(0.12, min(1, (level + 65) / 65)) : 0.55
                Capsule().fill(Color.accentTeal.opacity(active ? 0.8 : 0.3))
                    .frame(width: 5, height: 8 + 80 * envelope * detail * input)
            }
        }
    }
}

func openMicrophoneSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
}
