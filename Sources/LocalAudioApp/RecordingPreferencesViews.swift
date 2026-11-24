import SwiftUI
import LocalAudioCore

struct MicrophonePreferencesView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var capture: CaptureController
    init(store: AppStore) { self.store = store; capture = store.capture }
    private func update(_ edit: (inout MicrophonePolicy) -> Void) {
        var policy = store.microphonePolicy; edit(&policy); store.setMicrophonePolicy(policy)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Recording mode", selection: Binding(get: { store.microphonePolicy.mode }, set: { value in update { $0.mode = value } })) {
                Text("Manual · choose a microphone").tag(MicrophonePolicy.Mode.manual)
                Text("Approved microphones").tag(MicrophonePolicy.Mode.approved)
                Text("Mac microphone · always on").tag(MicrophonePolicy.Mode.macAlways)
            }
            Toggle("Allow the built-in Mac microphone", isOn: Binding(get: { store.microphonePolicy.allowMacMicrophone }, set: { value in
                update { $0.allowMacMicrophone = value; if !value && $0.mode == .macAlways { $0.mode = .approved } }
            }))
            Text(store.microphonePolicy.allowMacMicrophone ? "Choose your inputs below. Disconnection ends and saves the current recording." : "The built-in Mac microphone is blocked in every recording mode, including system default.")
                .font(.caption).foregroundStyle(.secondary)
            if store.microphonePolicy.mode == .approved {
                Text("Connect your intended microphones, then approve each one. One records at a time, in the order below.").font(.callout)
                ForEach(store.microphonePolicy.approved) { mic in
                    HStack {
                        Label(mic.name, systemImage: capture.devices.contains(where: { $0.id == mic.id }) ? "checkmark.circle" : "cable.connector.slash")
                        Spacer()
                        Button("Remove") { update { $0.approved.removeAll { $0.id == mic.id } } }.buttonStyle(.link)
                    }
                }
                ForEach(capture.devices.filter { mic in !store.microphonePolicy.approved.contains(where: { $0.id == mic.id }) && (store.microphonePolicy.allowMacMicrophone || !mic.isBuiltIn) }) { mic in
                    HStack { Text(mic.name); Spacer(); Button("Approve") { update { $0.approved.append(mic) } } }
                }
                if capture.devices.isEmpty { Text("No microphones detected. Connect yours, then Refresh.").foregroundStyle(.secondary) }
                Button("Refresh microphones") { capture.refreshInputs() }.buttonStyle(.link)
            }
            if store.microphonePolicy.mode != .manual {
                Text("Automatic recording starts only after you enable it below. It runs while LocalAudio is open and your Mac is awake, saving a new file every 30 minutes. Stop & Save pauses automatic recording. Enable it again after reopening the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(capture.isBusy || store.automaticRecordingArmed)
    }
}

struct AutomaticRecordingView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var capture: CaptureController
    init(store: AppStore) { self.store = store; capture = store.capture }
    var body: some View {
        if store.microphonePolicy.mode != .manual {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: store.automaticRecordingArmed ? "waveform.circle.fill" : "pause.circle").foregroundStyle(Color.accentTeal)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.automaticRecordingArmed ? "Automatic recording enabled" : "Automatic recording paused").font(.headline)
                    Text(store.automaticRecordingArmed ? "Waiting for an approved input when idle. A failed input needs reconnection or a fresh enable." : "Enable to start when an allowed input is available. Stop pauses it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(store.automaticRecordingArmed ? "Pause & Save" : "Enable Automatic Recording") { store.toggleAutomaticRecording() }
                    .disabled(store.showQuickStart || (capture.isBusy && !store.automaticRecordingArmed))
            }.padding(16).background(Color.accentTeal.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct AudioRetentionSettings: View {
    @ObservedObject var store: AppStore
    var body: some View {
        Picker("Keep ordinary audio", selection: Binding(get: { store.retention?.days ?? 0 }, set: { store.setRetention(days: $0 == 0 ? nil : $0) })) {
            Text("Until I remove it").tag(0)
            Text("7 days · recommended").tag(7)
            Text("30 days").tag(30)
        }.disabled(store.isManagingAudio)
        Text("Recommended: keep text, move audio to Trash after 7 days, unless saved to the vault. Cleanup requires a readable transcript and finished processing. Saved voice examples and confirmed voice recordings are also protected.")
            .font(.caption).foregroundStyle(.secondary)
        Text("Turning on or changing a limit gives existing audio a fresh full window. Age starts when audio enters this library, regardless of its editable recording date. Cleanup runs while the app is open; macOS controls when Trash is emptied.")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Text(ByteCountFormatter.string(fromByteCount: store.recordings.filter(\.hasAudio).reduce(0) { $0 + $1.bytes }, countStyle: .file) + " of library audio").foregroundStyle(.secondary)
            Spacer()
            Button("Clean Up Due Audio") { Task { await store.cleanUpAudio() } }.disabled(store.retention == nil || !store.canManageAudio)
        }
        if !store.canManageAudio { Text("Cleanup waits for current processing or file operations to finish.").font(.caption).foregroundStyle(.secondary) }
        if let status = store.storageStatus { Text(status).font(.caption).textSelection(.enabled) }
    }
}

struct PassagePicker: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var player: PlaybackController
    let item: AudioRecording
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var title = ""
    init(store: AppStore, item: AudioRecording) { self.store = store; self.item = item; player = store.player }
    private var valid: Bool { start.isFinite && end.isFinite && start >= 0 && end > start && end <= item.duration }
    var body: some View {
        DisclosureGroup("Save a passage to the vault") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Start (seconds)")
                    TextField("Start", value: $start, format: .number.precision(.fractionLength(0...3))).frame(width: 80)
                    Button("Mark Start") { start = min(item.duration, player.position) }
                    Spacer()
                }
                HStack {
                    Text("End (seconds)")
                    TextField("End", value: $end, format: .number.precision(.fractionLength(0...3))).frame(width: 80)
                    Button("Mark End") { end = min(item.duration, player.position) }
                    Spacer()
                }
                TextField("Passage title (optional)", text: $title).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Listen to Selection") { player.playClip(start: start, end: end) }.disabled(!valid)
                    Spacer()
                    Button("Save Passage Permanently") { Task { await store.savePassage(item, start: start, end: end, title: title) } }
                        .buttonStyle(.borderedProminent).disabled(!valid || !store.canManageAudio)
                }
                Text(valid ? "A separate audio copy will stay in the vault, even after the original audio expires." : "Mark a start and a later end while listening, or enter seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 8)
        }.font(.callout)
    }
}
