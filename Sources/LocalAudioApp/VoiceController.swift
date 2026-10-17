import AppKit
import Combine
import Foundation
import LocalAudioCore

@MainActor
final class VoiceController: ObservableObject {
    @Published private(set) var profiles: [VoiceProfile] = []
    @Published private(set) var analysis: VoiceAnalysis?
    @Published private(set) var isLoading = false
    @Published private(set) var isAnalyzing = false
    @Published private(set) var isEditing = false
    @Published private(set) var status = "Find speakers locally, then name the voices you recognize."
    @Published var error: String?
    let models: ModelManager
    var canAnalyze: () -> Bool = { true }
    var onWorkFinished: (() -> Void)?
    var isBusy: Bool { isAnalyzing || isEditing || models.isBusy }

    private let library: VoiceLibrary
    private let scratch: URL
    private var selected: AudioRecording?
    private var selectionID = UUID()
    private var operationID: UUID?
    private var workTask: Task<Void, Never>?
    private var mutations: [UUID: Task<Void, Never>] = [:]
    private var runner: WorkerProcess?
    private var shuttingDown = false
    private var updates = Set<AnyCancellable>()

    init(dataFolder: URL) {
        library = VoiceLibrary(folder: dataFolder.appendingPathComponent("Voices"))
        scratch = dataFolder.appendingPathComponent("VoiceScratch")
        let helper = WorkerProcess.speakerHelperURL()
        let logs = dataFolder.appendingPathComponent("WorkerScratch")
        models = ModelManager(storageDirectory: dataFolder.appendingPathComponent("SpeakerModels"), pack: .speakers, validator: { folder in
            try await WorkerProcess.validate(executable: helper, modelFolder: folder, logs: logs)
        })
        models.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &updates)
    }

    func start() async {
        async let selection: Void = models.refresh()
        await reloadProfiles()
        await selection
    }

    func select(_ item: AudioRecording?) async {
        let id = UUID(); selectionID = id
        selected = item; analysis = nil; isLoading = item != nil
        defer { if selectionID == id { isLoading = false } }
        guard let item else { return }
        do {
            let loaded = try await library.loadAnalysis(for: item)
            guard selectionID == id else { return }
            analysis = loaded
        } catch {
            if selectionID == id { self.error = error.localizedDescription }
        }
    }

    func reloadProfiles() async {
        do { profiles = try await library.profiles() }
        catch { self.error = error.localizedDescription }
    }

    func analyze(_ item: AudioRecording) async {
        guard !shuttingDown, !isAnalyzing, !isEditing, !models.isBusy, canAnalyze() else { return }
        guard models.isReady, let folder = models.modelDirectory else {
            error = "Download the optional speaker model in Settings, or choose its local folder."
            return
        }
        let id = UUID(); operationID = id; isAnalyzing = true; error = nil
        status = "Finding voices in “" + item.title + "”…"
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAnalysis(item, models: folder, operation: id)
        }
        workTask = task
        await task.value
        if operationID == id { operationID = nil; workTask = nil; isAnalyzing = false; onWorkFinished?() }
    }

    private func runAnalysis(_ item: AudioRecording, models folder: URL, operation: UUID) async {
        let directory = scratch.appendingPathComponent(operation.uuidString)
        defer { try? FileManager.default.removeItem(at: directory); runner = nil }
        do {
            let request = try await library.analysisRequest(for: item, modelID: ModelPack.speakers.modelID)
            try Task.checkCancellation()
            let requestURL = directory.appendingPathComponent("request.json")
            let resultURL = directory.appendingPathComponent("result.json")
            try PrivateJSON.write(request, to: requestURL)
            let worker = WorkerProcess(); runner = worker
            try await worker.run(executable: WorkerProcess.speakerHelperURL(), arguments: ["--analyze", requestURL.path, "--models", folder.path, "--output", resultURL.path], logs: scratch)
            try Task.checkCancellation()
            let result = try PrivateJSON.read(VoiceAnalysis.self, from: resultURL)
            let saved = try await library.saveAnalysis(result, for: item)
            await reloadProfiles()
            if selected?.id == item.id && selected?.url == item.url { analysis = saved }
            status = saved.turns.isEmpty ? "No separate speech turns were found. Your audio is unchanged." : "Voices found. Listen and confirm names; unmatched voices stay Unknown."
        } catch is CancellationError {
            status = "Voice analysis stopped. Your audio, profiles and earlier analysis are safe."
        } catch {
            self.error = error.localizedDescription
            status = "Voice analysis needs attention. Your earlier data is safe."
        }
    }

    func cancel() { workTask?.cancel(); runner?.cancel() }

    func beginShutdown() {
        shuttingDown = true
        cancel(); models.cancel()
    }

    func shutdownAndWait() async {
        beginShutdown()
        if let workTask { await workTask.value }
        for task in Array(mutations.values) { await task.value }
        await models.cancelAndWait()
    }

    func personName(for turn: VoiceTurn) -> String {
        guard let id = turn.confirmedPersonID else { return "Unknown" }
        return profiles.first { $0.id == id }?.name ?? "Unknown"
    }

    func suggestion(for turn: VoiceTurn) -> VoiceCandidate? {
        guard let analysis, turn.confirmedPersonID == nil else { return nil }
        return VoiceMatcher.suggestion(for: turn, in: analysis, profiles: profiles)
    }

    func confirm(_ turn: VoiceTurn, in item: AudioRecording, personID: String, expected: VoiceAnalysis? = nil) async {
        guard let snapshot = expected ?? analysis else { error = "Open the current voice analysis before confirming a name."; return }
        await mutate(item: item) { library in
            _ = try await library.confirm(turnID: turn.id, in: item, personID: personID, expected: snapshot)
        }
    }

    func name(_ turn: VoiceTurn, in item: AudioRecording, newName: String, expected: VoiceAnalysis? = nil) async {
        guard let snapshot = expected ?? analysis else { error = "Open the current voice analysis before naming a voice."; return }
        await mutate(item: item) { library in
            _ = try await library.name(turnID: turn.id, in: item, newName: newName, expected: snapshot)
        }
    }

    func unconfirm(_ turn: VoiceTurn, in item: AudioRecording, expected: VoiceAnalysis? = nil) async {
        guard let snapshot = expected ?? analysis else { error = "Open the current voice analysis before changing its name."; return }
        await mutate(item: item) { library in
            _ = try await library.unconfirm(turnID: turn.id, in: item, expected: snapshot)
        }
    }

    func rename(_ person: VoiceProfile, to name: String) async {
        await mutate(item: selected) { library in _ = try await library.renamePerson(id: person.id, name: name) }
    }

    func forget(_ person: VoiceProfile) async {
        await mutate(item: selected) { library in try await library.deletePerson(id: person.id) }
    }

    private func mutate(item: AudioRecording?, operation: @escaping (VoiceLibrary) async throws -> Void) async {
        guard !shuttingDown, !isEditing, !isAnalyzing else { return }
        let id = UUID(); isEditing = true; error = nil
        let library = library
        let task = Task { [weak self] in
            do {
                try await operation(library)
                guard let self else { return }
                await self.reloadProfiles()
                if let item, self.selected?.id == item.id { await self.select(item) }
            } catch { self?.error = error.localizedDescription }
        }
        mutations[id] = task
        await task.value
        mutations[id] = nil; isEditing = !mutations.isEmpty
        onWorkFinished?()
    }

    /// A transcript chunk may contain multiple people. Only a single explicitly
    /// confirmed person covering the chunk earns a name; all other cases abstain.
    func confirmedName(start: Double, end: Double) -> String? {
        guard let analysis, end > start else { return nil }
        let turns = analysis.turns.filter { min(end, $0.end) - max(start, $0.start) > 0.02 }
        guard !turns.isEmpty, turns.allSatisfy({ $0.confirmedPersonID != nil }) else { return nil }
        let ids = Set(turns.compactMap(\.confirmedPersonID))
        guard ids.count == 1, let id = ids.first, let person = profiles.first(where: { $0.id == id }) else { return nil }
        var covered = 0.0, boundary = start
        for turn in turns.sorted(by: { $0.start < $1.start }) {
            let low = max(start, turn.start), high = min(end, turn.end)
            if high > max(boundary, low) { covered += high - max(boundary, low) }
            boundary = max(boundary, high)
        }
        return covered / (end - start) >= 0.9 ? person.name : nil
    }

    func validatedExportedText(_ transcript: LocalTranscript, item: AudioRecording) async throws -> String {
        do {
            let current = try await library.loadAnalysis(for: item)
            let people = try await library.profiles()
            guard selected?.id == item.id else { throw LocalAudioError.message("The selected recording changed. Export it again from the library.") }
            analysis = current; profiles = people
            return exportedText(transcript, item: item)
        } catch {
            if selected?.id == item.id { analysis = nil }
            throw error
        }
    }

    func exportedText(_ transcript: LocalTranscript, item: AudioRecording) -> String {
        guard selected?.id == item.id, analysis != nil, !transcript.segments.isEmpty else {
            return transcript.exportedText(title: item.title, recordedAt: item.date)
        }
        let formatter = DateFormatter(); formatter.dateFormat = "h:mm:ss a"
        let lines = transcript.segments.map { segment in
            let time = formatter.string(from: item.date.addingTimeInterval(segment.start))
            return "[" + time + "] " + (confirmedName(start: segment.start, end: segment.end) ?? "Unknown") + ": " + segment.text
        }
        return item.title + "\nRecorded: " + ISO8601DateFormatter().string(from: item.date) + "\nTranscribed locally with " + transcript.model + "\nNames are human-confirmed; Unknown means unconfirmed or mixed speakers.\n\n" + lines.joined(separator: "\n\n") + "\n"
    }
}
