import SwiftUI
import AppKit
import LocalAudioCore

extension Color {
    static let accentTeal = Color(red: 0.08, green: 0.46, blue: 0.43)
}

func clock(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let value = Int(max(0, seconds))
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
}

struct RootView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var models: ModelManager
    @State private var section = "record"
    init(store: AppStore) { self.store = store; models = store.models }
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.title2.weight(.semibold)).foregroundStyle(Color.accentTeal)
                    Text("LocalAudio").font(.title3.weight(.semibold))
                    Spacer()
                }.padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 22)
                VStack(spacing: 4) {
                    sidebarButton("Record", image: "record.circle", destination: "record")
                    sidebarButton("Library", image: "rectangle.stack", destination: "library")
                }.padding(.horizontal, 10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                VStack(alignment: .leading, spacing: 14) {
                    SettingsLink { Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                    Divider()
                    Label("Stored on this Mac", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 245)
        } detail: {
            if section == "record" { RecordView(store: store, openLibrary: { section = "library" }) }
            else { LibraryView(store: store, record: { section = "record" }) }
        }
        .disabled(store.isShuttingDown)
        .onReceive(models.$isReady) { if $0 { store.processNext() } }
        .alert("LocalAudio", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private func sidebarButton(_ title: String, image: String, destination: String) -> some View {
        Button { section = destination } label: {
            HStack(spacing: 9) {
                Image(systemName: image).frame(width: 20)
                Text(title)
                Spacer()
                if destination == "library" { Text("\(store.recordings.count)").font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 10).padding(.vertical, 9)
                .contentShape(Rectangle())
                .background(section == destination ? Color.accentTeal.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}

struct RecordView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var capture: CaptureController
    @ObservedObject private var models: ModelManager
    let openLibrary: () -> Void
    init(store: AppStore, openLibrary: @escaping () -> Void) { self.store = store; capture = store.capture; models = store.models; self.openLibrary = openLibrary }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Record audio").font(.largeTitle.weight(.bold))
                    Text("Choose a microphone. Your original audio stays on this Mac.").foregroundStyle(.secondary)
                }
                VStack(spacing: 28) {
                    HStack {
                        Label("MICROPHONE", systemImage: "mic").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Picker("Microphone", selection: $capture.selectedDeviceID) {
                            Text("System default").tag(nil as String?)
                            ForEach(capture.devices) { input in Text(input.name).tag(Optional(input.id)) }
                        }.labelsHidden().frame(maxWidth: 330)
                        .disabled(capture.isRecording || capture.isStarting || capture.isFinalizing)
                        Button { capture.refreshInputs() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Refresh audio inputs")
                    }
                    VStack(spacing: 14) {
                        Image(systemName: capture.isRecording ? "waveform" : "mic.fill")
                            .font(.system(size: 48, weight: .light)).foregroundStyle(capture.isRecording ? .red : Color.accentTeal)
                            .frame(width: 104, height: 104).background(Color.accentTeal.opacity(0.08), in: Circle())
                        Text(clock(capture.elapsed)).font(.system(size: 52, weight: .light, design: .rounded)).monospacedDigit()
                        Text(capture.isFinalizing ? "Saving your recording…" : capture.isStarting ? "Starting microphone…" : capture.isRecording ? "Recording" : "Ready when you are")
                            .foregroundStyle(capture.isRecording ? .red : .secondary)
                        LevelMeter(level: capture.level, active: capture.isRecording)
                            .frame(maxWidth: 290).accessibilityLabel("Microphone input level")
                    }.padding(.vertical, 12)
                    HStack(spacing: 14) {
                        if capture.isRecording || capture.isStarting {
                            Button { Task { await capture.stop() } } label: { Label("Stop & Save", systemImage: "stop.fill").frame(width: 150) }
                                .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                        } else {
                            Button { Task { await store.startRecording() } } label: { Label("Record", systemImage: "record.circle.fill").frame(width: 150) }
                                .buttonStyle(.borderedProminent).controlSize(.large).disabled(capture.isFinalizing)
                        }
                        Button("Import Audio…") { store.importFiles(); openLibrary() }.controlSize(.large).disabled(store.isImporting)
                    }
                    if let error = capture.lastError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                .padding(28).background(.background, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(.quaternary, lineWidth: 1))
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "doc.text").foregroundStyle(Color.accentTeal).font(.title2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(models.isReady ? "Local transcription is ready" : "Add transcription when you want it").font(.headline)
                        Text(models.isReady ? "New audio can be transcribed here, without an internet connection." : "Recording works now. Install the English model in Settings to turn audio into text on this Mac.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    SettingsLink { Text(models.isReady ? "Settings" : "Set Up") }.buttonStyle(.bordered)
                }.padding(20).background(Color.accentTeal.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                HStack {
                    Label(store.recordingsFolder.lastPathComponent, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Recordings") { showFolder(store.recordingsFolder) }.buttonStyle(.link).font(.caption)
                }
                if store.isProcessing {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Transcribing “" + store.processingTitle + "” locally").font(.callout).foregroundStyle(.secondary) }
                }
            }.padding(36).frame(maxWidth: 850)
                .frame(maxWidth: .infinity)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: capture.selectedDeviceID) { _, _ in store.savePreferences() }
    }
}

struct LevelMeter: View {
    let level: Double
    let active: Bool
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<36, id: \.self) { index in
                let illuminated = active && Double(index) / 36 < max(0, min(1, (level + 65) / 65))
                RoundedRectangle(cornerRadius: 2).fill(illuminated ? (index > 32 ? Color.red : Color.accentTeal) : Color.secondary.opacity(0.12)).frame(height: 8)
            }
        }
    }
}

struct LibraryView: View {
    @ObservedObject var store: AppStore
    @State private var search = ""
    let record: () -> Void
    var filtered: [AudioRecording] { search.isEmpty ? store.recordings : store.recordings.filter { $0.title.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text("Your library").font(.title.weight(.bold)); Text("Original audio. Local transcripts.").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh library")
                Button("Import Audio…") { store.importFiles() }.disabled(store.isImporting)
                Button("Record", action: record).buttonStyle(.borderedProminent)
            }.padding(24)
            if !store.libraryWarnings.isEmpty {
                DisclosureGroup("Some files need attention (\(store.libraryWarnings.count))") {
                    ScrollView { Text(store.libraryWarnings.joined(separator: "\n")).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100)
                }.foregroundStyle(.orange).padding(.horizontal, 24).padding(.bottom, 12)
            }
            Divider()
            if store.isLibraryLoading && store.recordings.isEmpty {
                VStack(spacing: 16) {
                    ProgressView("Opening your recording folder…")
                    Text("If macOS asks for folder access, respond to its prompt. You can choose a different folder in Settings.").font(.callout).foregroundStyle(.secondary)
                    SettingsLink { Text("Open Settings") }
                }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.recordings.isEmpty {
                ContentUnavailableView {
                    Label("Your audio belongs here", systemImage: "waveform")
                } description: { Text("Record from a microphone or import an audio file. It stays on your Mac.") }
                actions: { Button("Record Audio", action: record).buttonStyle(.borderedProminent); Button("Import Audio…") { store.importFiles() } }
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        TextField("Filter recording titles", text: $search).textFieldStyle(.roundedBorder).padding(12)
                        List(selection: $store.selection) {
                            ForEach(filtered) { item in
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(item.title).font(.headline).lineLimit(2)
                                    HStack { Text(item.date, format: .dateTime.month(.abbreviated).day().hour().minute()); Spacer(); Text(clock(item.duration)).monospacedDigit() }.font(.caption).foregroundStyle(.secondary)
                                    if let job = store.job(for: item) {
                                        Label(job.status == .failed ? "Needs attention" : job.status == .running ? "Transcribing" : store.models.isReady ? "Queued" : "Waiting for model", systemImage: job.status == .failed ? "exclamationmark.circle" : "clock").font(.caption).foregroundStyle(job.status == .failed ? .orange : .secondary)
                                    } else if FileManager.default.fileExists(atPath: item.transcriptURL.path) {
                                        Label("Transcript ready", systemImage: "checkmark.circle").font(.caption).foregroundStyle(Color.accentTeal)
                                    }
                                }.padding(.vertical, 9).tag(item.id)
                            }
                        }.listStyle(.inset)
                    }.frame(minWidth: 230, idealWidth: 275, maxWidth: 340)
                    if store.selected != nil { RecordingDetail(store: store) }
                    else { ContentUnavailableView("Choose a recording", systemImage: "doc.text") }
                }
            }
        }
        .overlay { if store.isImporting { ProgressView("Importing copies…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .onChange(of: store.selection) { _, _ in Task { await store.loadSelection() } }
    }
}

struct RecordingDetail: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var player: PlaybackController
    @State private var query = ""
    init(store: AppStore) { self.store = store; player = store.player }
    var body: some View {
        if let item = store.selected {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        TextField("Recording title", text: $store.titleDraft).textFieldStyle(.plain).font(.title2.weight(.semibold)).onSubmit { Task { await store.saveDetails() } }
                        DatePicker("Recorded", selection: $store.dateDraft).font(.caption).labelsHidden()
                        HStack { Button("Save Details") { Task { await store.saveDetails() } }.buttonStyle(.link); Text(clock(item.duration) + " · " + ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).foregroundStyle(.secondary) }.font(.caption)
                    }
                    Spacer()
                    Menu { Button("Show Audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }; Button("Export Transcript…") { store.exportTranscript() }.disabled(store.transcript == nil) } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 30)
                }
                VStack(spacing: 10) {
                    Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0...max(0.1, player.duration)).accessibilityLabel("Audio playback position")
                    HStack {
                        Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 24) }.buttonStyle(.borderedProminent)
                        Button { player.seek(player.position - 15) } label: { Image(systemName: "gobackward.15") }
                        Button { player.seek(player.position + 15) } label: { Image(systemName: "goforward.15") }
                        Text(clock(player.position) + " / " + clock(player.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Picker("Speed", selection: $player.rate) { Text("0.75×").tag(Float(0.75)); Text("1×").tag(Float(1)); Text("1.25×").tag(Float(1.25)); Text("1.5×").tag(Float(1.5)); Text("2×").tag(Float(2)) }.frame(width: 112).labelsHidden()
                    }
                }.padding(16).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                if let error = player.error { Text(error).foregroundStyle(.orange).font(.callout) }
                Divider()
                HStack {
                    Label("Transcript", systemImage: "doc.text").font(.headline)
                    Spacer()
                    if store.job(for: item)?.status == .running { ProgressView().controlSize(.small) }
                    else { Button(store.transcript == nil ? "Transcribe" : "Transcribe Again") { store.enqueue(item) } }
                    Button { store.exportTranscript() } label: { Image(systemName: "square.and.arrow.up") }.disabled(store.transcript == nil).help("Export readable text")
                }
                if let failure = store.job(for: item)?.error { Text(failure).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                if let error = store.transcriptError { Text(error).font(.callout).foregroundStyle(.orange) }
                if let transcript = store.transcript {
                    TextField("Find transcript text", text: $query).textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            if transcript.segments.isEmpty { Text(transcript.text.isEmpty ? "No speech was detected in this recording." : transcript.text).textSelection(.enabled) }
                            ForEach(transcript.segments.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }) { segment in
                                VStack(alignment: .leading, spacing: 6) {
                                    Button { player.jump(to: segment.start) } label: { Text(item.date.addingTimeInterval(segment.start), format: .dateTime.hour().minute().second()).font(.caption.monospacedDigit()) }.buttonStyle(.link)
                                    Text(segment.text).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }.padding(.vertical, 8)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(store.job(for: item)?.status == .running ? "Turning audio into text on your Mac…" : store.models.isReady ? "A transcript is one click away." : "Set up the English model in Settings to transcribe this recording.").foregroundStyle(.secondary)
                        Text("Your original audio is already saved.").font(.caption).foregroundStyle(.secondary)
                        if !store.models.isReady { SettingsLink { Text("Open Settings") } }
                    }.padding(.vertical, 18)
                    Spacer()
                }
            }.padding(24).frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onChange(of: item.id) { _, _ in query = "" }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var models: ModelManager
    init(store: AppStore) { self.store = store; models = store.models }
    var body: some View {
        Form {
            Section("Recordings") {
                LabeledContent("Folder") { Text(store.recordingsFolder.path).lineLimit(2).textSelection(.enabled); Button("Choose…") { store.chooseFolder() }.disabled(!store.canChangeFolder) }
                Toggle("Transcribe new recordings and imports", isOn: $store.automaticallyTranscribe).onChange(of: store.automaticallyTranscribe) { _, _ in store.savePreferences() }
                Text("Original audio is always kept. Transcription waits safely until a model is ready.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Local transcription") {
                LabeledContent("English model", value: models.isReady ? "Ready on this Mac" : "Optional · about 464 MB")
                Text(models.statusText).font(.callout).textSelection(.enabled)
                if models.isBusy {
                    if let progress = models.progress { ProgressView(value: progress) } else { ProgressView() }
                    Button("Cancel Setup") { models.cancel() }
                } else {
                    HStack {
                        Button(models.isReady ? "Repair / Re-download" : "Download English Model") { Task { guard !store.isShuttingDown else { return }; await models.install(); store.processNext() } }.buttonStyle(.borderedProminent).disabled(store.isProcessing)
                        Button("Use a Local Model…") { chooseModel() }.disabled(store.isProcessing)
                    }
                }
                if let directory = models.modelDirectory { Text(directory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Text("Only model setup downloads files. Audio, transcripts and processing stay local. No account is required.").font(.caption).foregroundStyle(.secondary)
                Text("Parakeet TDT v2 by NVIDIA. Core ML conversion by FluidInference. Downloaded model files are unmodified.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Link("Model source", destination: URL(string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml/tree/ee09c569f73759e6d44c9bd16766f477b2b36d39")!)
                    Link("CC-BY-4.0 license", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                    Button("Software licenses") {
                        if let url = Bundle.main.resourceURL?.appendingPathComponent("THIRD_PARTY_NOTICES.md") { NSWorkspace.shared.open(url) }
                    }.buttonStyle(.link)
                }.font(.caption)
            }
            Section("Transcription work") {
                if store.jobs.isEmpty { Text("All caught up.").foregroundStyle(.secondary) }
                else {
                    Text(store.isProcessing ? "Transcribing “" + store.processingTitle + "”" : store.queuePaused ? "Paused" : models.isReady ? "Ready to continue" : "Waiting for model setup")
                    ForEach(store.jobs) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.title).font(.callout.weight(.medium))
                            if let error = job.error { Text(error).font(.caption).foregroundStyle(.orange) }
                        }
                    }
                    Button(store.queuePaused ? "Resume" : "Pause") { store.queuePaused ? store.resumeQueue() : store.pauseQueue() }
                }
            }
            Section {
                Label("Stored and processed on your Mac", systemImage: "lock.shield").foregroundStyle(Color.accentTeal)
                Text("LocalAudio records your selected microphone only. It does not record system audio. Keep consent and your surroundings in mind when recording.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding(16).frame(width: 650, height: 680).disabled(store.isShuttingDown)
    }
    private func chooseModel() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose a Parakeet v2 folder containing four .mlmodelc bundles and parakeet_vocab.json. The folder is read in place."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { guard !store.isShuttingDown else { return }; do { try await models.useLocalFolder(url); store.processNext() } catch { store.errorMessage = error.localizedDescription } }
    }
}

func showFolder(_ folder: URL) {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    NSWorkspace.shared.open(folder)
}
