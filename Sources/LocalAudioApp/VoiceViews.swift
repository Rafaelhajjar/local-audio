import SwiftUI
import AppKit
import LocalAudioCore

private struct VoiceNamingRequest: Identifiable {
    let turn: VoiceTurn
    let analysis: VoiceAnalysis
    var id: String { turn.id }
}

struct RecordingVoicesView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var voices: VoiceController
    @ObservedObject private var models: ModelManager
    let item: AudioRecording
    @State private var naming: VoiceNamingRequest?
    init(store: AppStore, item: AudioRecording) { self.store = store; self.item = item; voices = store.voices; models = store.voices.models }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Voices in this recording", systemImage: "person.wave.2").font(.headline)
                Spacer()
                if voices.isAnalyzing {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { voices.cancel() }
                } else {
                    Button(voices.analysis == nil ? "Find Voices" : "Analyze Again") { Task { await voices.analyze(item) } }
                        .disabled(!models.isReady || models.isBusy || store.isProcessing || voices.isEditing)
                }
            }
            Text("Names stay Unknown until you confirm them. Possible matches are experimental suggestions; they never name or train a voice automatically.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = voices.error { VoiceErrorBanner(voices: voices, message: error) }
            if voices.isLoading {
                ProgressView("Reading saved voice analysis…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let analysis = voices.analysis, analysis.recordingID == item.id {
                if analysis.turns.isEmpty {
                    ContentUnavailableView("No speech turns found", systemImage: "waveform", description: Text("The recording is unchanged. Short or silent audio may not contain usable voices."))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(analysis.turns) { turn in
                                turnRow(turn, analysis: analysis)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            } else if !models.isReady {
                ContentUnavailableView {
                    Label("Add local voice recognition", systemImage: "person.wave.2")
                } description: {
                    Text("Install the optional speaker model in Settings once. Speaker analysis, profiles and matching then work offline.")
                } actions: {
                    SettingsLink { Text("Open Settings") }.buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView {
                    Label(voices.isAnalyzing ? "Finding voices locally…" : "Name the voices you recognize", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text(voices.isAnalyzing ? voices.status : "Find Voices groups speech into anonymous turns. Listen to a turn, then choose a saved person or enter a new name.")
                }
            }
        }
        .sheet(item: $naming) { request in NameVoiceSheet(voices: voices, player: store.player, recording: item, turn: request.turn, expectedAnalysis: request.analysis) }
        .onChange(of: item.id) { _, _ in naming = nil }
        .onChange(of: voices.analysis?.createdAt) { _, _ in naming = nil }
        .onChange(of: voices.isAnalyzing) { _, active in if active { naming = nil } }
    }

    private func turnRow(_ turn: VoiceTurn, analysis: VoiceAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(voices.personName(for: turn), systemImage: turn.confirmedPersonID == nil ? "person.crop.circle.badge.questionmark" : "person.crop.circle.fill")
                        .font(.headline).foregroundStyle(turn.confirmedPersonID == nil ? Color.secondary : Color.accentTeal)
                    Text(item.date.addingTimeInterval(turn.start), format: .dateTime.hour().minute().second())
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(clock(turn.start) + "–" + clock(turn.end) + " · " + turn.speakerID)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Listen") { store.player.playClip(start: turn.start, end: turn.end) }
                Button(turn.confirmedPersonID == nil ? "Name This Voice…" : "Change Name…") { naming = VoiceNamingRequest(turn: turn, analysis: analysis) }
                    .disabled(voices.isBusy)
            }
            if turn.confirmedPersonID != nil {
                HStack {
                    Text("Confirmed by you").font(.caption).foregroundStyle(Color.accentTeal)
                    Spacer()
                    Button("Keep Unknown") { Task { await voices.unconfirm(turn, in: item, expected: analysis) } }.buttonStyle(.link).font(.caption).disabled(voices.isBusy)
                }
            } else if let suggestion = voices.suggestion(for: turn) {
                HStack {
                    Text("Possible match: " + suggestion.name).font(.callout)
                    Spacer()
                    Button("Confirm “" + suggestion.name + "”") { Task { await voices.confirm(turn, in: item, personID: suggestion.personID, expected: analysis) } }
                        .disabled(voices.isBusy)
                }
                Text("Listen before confirming. This is not a verified identity.").font(.caption).foregroundStyle(.secondary)
            } else if turn.embedding == nil {
                Text("No clean voice example is available for matching. You can still label this turn manually.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct NameVoiceSheet: View {
    @ObservedObject var voices: VoiceController
    let player: PlaybackController
    let recording: AudioRecording
    let turn: VoiceTurn
    let expectedAnalysis: VoiceAnalysis
    @State private var personID = "__new__"
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Name this voice").font(.title2.weight(.semibold))
            Text("Confirm who speaks in this turn. If it contains mixed or uncertain voices, leave it Unknown.").foregroundStyle(.secondary)
            HStack {
                Text(clock(turn.start) + "–" + clock(turn.end)).font(.callout.monospacedDigit())
                Spacer()
                Button("Listen to Turn") { player.playClip(start: turn.start, end: turn.end) }
            }
            Picker("Person", selection: $personID) {
                Text("Create a new person").tag("__new__")
                ForEach(voices.profiles) { person in Text(person.name).tag(person.id) }
            }
            if personID == "__new__" { TextField("Person name", text: $name).textFieldStyle(.roundedBorder) }
            Text(turn.embedding == nil
                ? "This name will label the turn only. No clean example is available to add to the voice profile."
                : "This confirmation labels this turn. Any usable clean example is added to the local profile for later matching.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = voices.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Text("Stored only on this Mac").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Confirm Name") {
                    Task {
                        if personID == "__new__" { await voices.name(turn, in: recording, newName: name, expected: expectedAnalysis) }
                        else { await voices.confirm(turn, in: recording, personID: personID, expected: expectedAnalysis) }
                        if voices.error == nil { dismiss() }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(voices.isBusy || (personID == "__new__" && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }.padding(26).frame(width: 510).disabled(voices.isEditing)
    }
}

struct PeopleView: View {
    @ObservedObject var voices: VoiceController
    @State private var renaming: VoiceProfile?
    @State private var forgetting: VoiceProfile?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("People").font(.largeTitle.weight(.bold))
            Text("Names and voice examples stay on this Mac. Only your confirmations add examples; recognition suggestions never train profiles.").foregroundStyle(.secondary)
            if let error = voices.error { VoiceErrorBanner(voices: voices, message: error) }
            if voices.profiles.isEmpty {
                ContentUnavailableView("No saved voices yet", systemImage: "person.2", description: Text("Open a recording in Library, choose Voices, and name a voice after listening. Your saved people will appear here."))
            } else {
                List {
                    ForEach(voices.profiles) { person in
                        HStack(spacing: 14) {
                            Image(systemName: "person.crop.circle.fill").font(.title).foregroundStyle(Color.accentTeal)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(person.name).font(.headline)
                                Text("\(person.examples.count) confirmed voice example\(person.examples.count == 1 ? "" : "s") · \(Set(person.examples.map(\.audioHash)).count) recording\(Set(person.examples.map(\.audioHash)).count == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Rename") { renaming = person }
                            Button("Forget…") { forgetting = person }
                        }.padding(.vertical, 10)
                    }
                }.listStyle(.inset).disabled(voices.isBusy)
            }
            Text("Voice matching is experimental and is not identity verification. A voice stays Unknown until you confirm a name.").font(.caption).foregroundStyle(.secondary)
        }.padding(36)
        .sheet(item: $renaming) { person in RenamePersonSheet(voices: voices, person: person) }
        .confirmationDialog("Forget this person?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible) {
            if let person = forgetting {
                Button("Forget “" + person.name + "”", role: .destructive) { Task { await voices.forget(person); forgetting = nil } }
            }
            Button("Cancel", role: .cancel) { forgetting = nil }
        } message: { Text("Remove their saved voice examples and name confirmations. Recordings and transcript text stay unchanged.") }
    }
}

private struct RenamePersonSheet: View {
    @ObservedObject var voices: VoiceController
    let person: VoiceProfile
    @State private var name: String
    @Environment(\.dismiss) private var dismiss
    init(voices: VoiceController, person: VoiceProfile) { self.voices = voices; self.person = person; _name = State(initialValue: person.name) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename person").font(.title2.weight(.semibold))
            TextField("Person name", text: $name).textFieldStyle(.roundedBorder)
            if let error = voices.error { Text(error).foregroundStyle(.orange).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Name") { Task { await voices.rename(person, to: name); if voices.error == nil { dismiss() } } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || voices.isBusy)
            }
        }.padding(24).frame(width: 390)
    }
}

struct VoiceErrorBanner: View {
    @ObservedObject var voices: VoiceController
    let message: String
    var body: some View {
        HStack(alignment: .top) {
            Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            Spacer()
            Button("Dismiss") { voices.error = nil }.buttonStyle(.link)
        }
    }
}

struct SpeakerModelSettings: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var models: ModelManager
    init(store: AppStore) { self.store = store; models = store.voices.models }
    var body: some View {
        Section("Local voices") {
            LabeledContent("Speaker model", value: models.isReady ? "Ready on this Mac" : "Optional · about 22 MB")
            Text(models.statusText).font(.callout).textSelection(.enabled)
            if models.isBusy {
                if let progress = models.progress { ProgressView(value: progress) } else { ProgressView() }
                Button("Cancel Speaker Setup") { models.cancel() }
            } else {
                HStack {
                    Button(models.isReady ? "Repair Speaker Model" : "Download Speaker Model") {
                        Task { guard !store.isShuttingDown else { return }; await models.install(); store.processNext() }
                    }.buttonStyle(.borderedProminent).disabled(store.isProcessing || store.voices.isAnalyzing)
                    Button("Use Local Speaker Model…") { chooseModel() }.disabled(store.isProcessing || store.voices.isAnalyzing)
                }
            }
            Text("Speaker analysis and named profiles stay local. Suggestions require your confirmation; unknown or ambiguous voices are never named automatically.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Community-1 segmentation, WeSpeaker embeddings and VBx parameters; Core ML conversions by FluidInference. Selected assets: CC-BY-4.0. LocalAudio downloads the converted files unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Link("Model source and attribution", destination: URL(string: "https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/7eab74f3463c736418d0eb10296261ae581146c9/NOTICE.md")!)
                Link("CC-BY-4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
            }.font(.caption)
        }
    }
    private func chooseModel() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose the speaker model folder containing Segmentation, FBank, Embedding, PldaRho and plda-parameters.json. It will be read in place."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { guard !store.isShuttingDown else { return }; do { try await models.useLocalFolder(folder) } catch { store.voices.error = error.localizedDescription }; store.processNext() }
    }
}
