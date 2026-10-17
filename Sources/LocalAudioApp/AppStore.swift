import SwiftUI
import Combine
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LocalAudioCore

struct AppPreferences: Codable {
    var recordingsFolder: URL
    var inputID: String?
    var automaticallyTranscribe = true
}

@MainActor
final class AppStore: ObservableObject {
    @Published var recordings: [AudioRecording] = []
    @Published var selection: String?
    @Published var errorMessage: String?
    @Published var libraryWarnings: [String] = []
    @Published var isLibraryLoading = false
    @Published var isImporting = false
    @Published var isProcessing = false
    @Published var processingTitle = ""
    @Published var jobs: [TranscriptionJob] = []
    @Published var queuePaused = false
    @Published private(set) var isShuttingDown = false
    @Published var automaticallyTranscribe: Bool
    @Published var recordingsFolder: URL
    @Published var transcript: LocalTranscript?
    @Published var transcriptError: String?
    @Published var titleDraft = ""
    @Published var dateDraft = Date()
    let models: ModelManager
    let capture = CaptureController()
    let player = PlaybackController()
    let dataFolder: URL
    private var library: RecordingLibrary
    private var preferences: AppPreferences
    private var runner: WorkerProcess?
    private var processingTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var registrationTasks: [UUID: Task<Void, Never>] = [:]
    private var jobsWritable = true
    private var preferencesWritable = true
    private var hasStarted = false
    private var latestScanID = UUID()
    private var presentationUpdates = Set<AnyCancellable>()

    var selected: AudioRecording? { recordings.first { $0.id == selection } }
    var pendingCount: Int { jobs.filter { $0.status != .failed }.count }
    var canChangeFolder: Bool { !isShuttingDown && !capture.isRecording && !capture.isStarting && !capture.isFinalizing && !isProcessing && !isImporting && registrationTasks.isEmpty }

    func startRecording() async {
        guard !isShuttingDown else { return }
        player.pause()
        await capture.start(in: recordingsFolder)
    }

    init(paths: LaunchPaths) {
        dataFolder = paths.data
        let settingsURL = paths.data.appendingPathComponent("settings.json")
        let defaultFolder = paths.recordingsOverride ?? (paths.isIsolated
            ? paths.data.appendingPathComponent("Recordings")
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/LocalAudio Recordings"))
        var preferences = AppPreferences(recordingsFolder: defaultFolder)
        var initialError: String?
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            do { preferences = try PrivateJSON.read(AppPreferences.self, from: settingsURL) }
            catch { initialError = "Saved settings could not be read and have been preserved. " + error.localizedDescription; preferencesWritable = false }
        }
        if let override = paths.recordingsOverride { preferences.recordingsFolder = override }
        self.preferences = preferences
        recordingsFolder = preferences.recordingsFolder
        automaticallyTranscribe = preferences.automaticallyTranscribe
        library = RecordingLibrary(folder: preferences.recordingsFolder)
        let logs = paths.data.appendingPathComponent("WorkerScratch")
        let helper = WorkerProcess.helperURL()
        models = ModelManager(storageDirectory: paths.data.appendingPathComponent("Models"), validator: { folder in
            try await WorkerProcess.validate(executable: helper, modelFolder: folder, logs: logs)
        })
        let jobsURL = paths.data.appendingPathComponent("jobs.json")
        if FileManager.default.fileExists(atPath: jobsURL.path) {
            do {
                jobs = try PrivateJSON.read([TranscriptionJob].self, from: jobsURL)
                for index in jobs.indices where jobs[index].status == .running { jobs[index].status = .queued }
            } catch { initialError = "The unfinished transcription list could not be read and has been preserved. " + error.localizedDescription; jobsWritable = false }
        }
        capture.selectedDeviceID = preferences.inputID
        capture.onSaved = { [weak self] url in
            guard let self else { return }
            let id = UUID()
            self.registrationTasks[id] = Task { @MainActor in
                await self.recordingSaved(url)
                self.registrationTasks[id] = nil
            }
        }
        errorMessage = initialError
        // Computed store values depend on nested state. Forward state changes,
        // while keeping high-frequency audio meter updates in the capture view.
        capture.$isRecording.combineLatest(capture.$isStarting, capture.$isFinalizing)
            .removeDuplicates { a, b in a.0 == b.0 && a.1 == b.1 && a.2 == b.2 }
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &presentationUpdates)
        models.$isReady.removeDuplicates()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &presentationUpdates)
    }

    func start() async {
        guard !hasStarted, !isShuttingDown else { return }; hasStarted = true
        async let scan: Void = refresh()
        await models.refresh()
        await scan
        processNext()
    }

    func refresh() async {
        let requestedLibrary = library
        let scanID = UUID(); latestScanID = scanID
        isLibraryLoading = true
        defer { if latestScanID == scanID { isLibraryLoading = false } }
        do {
            let scan = try await requestedLibrary.scanWithWarnings()
            guard library === requestedLibrary, latestScanID == scanID else { return }
            recordings = scan.recordings; libraryWarnings = scan.warnings
            if !recordings.contains(where: { $0.id == selection }) { selection = recordings.first?.id }
            await loadSelection()
        } catch { if library === requestedLibrary { errorMessage = error.localizedDescription } }
    }

    func loadSelection() async {
        player.load(selected)
        transcript = nil; transcriptError = nil
        guard let selected else { return }
        titleDraft = selected.title; dateDraft = selected.date
        guard FileManager.default.fileExists(atPath: selected.transcriptURL.path) else { return }
        do {
            let loaded = try PrivateJSON.read(LocalTranscript.self, from: selected.transcriptURL)
            guard loaded.version == 1 else { throw LocalAudioError.message("This transcript needs a newer LocalAudio version.") }
            transcript = loaded
        } catch { transcriptError = "This transcript could not be read. It has not been changed. " + error.localizedDescription }
    }

    func saveDetails() async {
        guard let selected else { return }
        do { try await library.update(selected, title: titleDraft, date: dateDraft); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func savePreferences() {
        preferences.inputID = capture.selectedDeviceID
        preferences.automaticallyTranscribe = automaticallyTranscribe
        preferences.recordingsFolder = recordingsFolder
        guard preferencesWritable else { return }
        do { try PrivateJSON.write(preferences, to: dataFolder.appendingPathComponent("settings.json")) }
        catch { errorMessage = "Settings could not be saved: " + error.localizedDescription }
    }

    func chooseFolder() {
        guard canChangeFolder else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "Choose where LocalAudio saves original recordings and imported copies."
        panel.directoryURL = recordingsFolder
        guard panel.runModal() == .OK, let folder = panel.url, canChangeFolder else { return }
        recordingsFolder = folder; library = RecordingLibrary(folder: folder); selection = nil; player.pause(); savePreferences()
        Task { await refresh() }
    }

    func importFiles() {
        guard !isShuttingDown, !isLibraryLoading, !isImporting else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = true
        panel.message = "Import copies of your audio files. The originals stay where they are."
        guard panel.runModal() == .OK, !isShuttingDown else { return }
        let urls = panel.urls; isImporting = true
        importTask = Task {
            defer { isImporting = false; importTask = nil }
            var errors: [String] = []
            for url in urls {
                do {
                    let item = try await library.importAudio(url)
                    await refresh(); selection = item.id
                    if automaticallyTranscribe { enqueue(item) }
                } catch { errors.append(url.lastPathComponent + ": " + error.localizedDescription) }
            }
            await loadSelection()
            if !errors.isEmpty { errorMessage = errors.joined(separator: "\n") }
        }
    }

    private func recordingSaved(_ url: URL) async {
        do {
            let item = try await library.registerSaved(url)
            await refresh(); selection = item.id; await loadSelection()
            if automaticallyTranscribe { enqueue(item) }
        } catch { errorMessage = "Audio was saved, but its details could not be registered: " + error.localizedDescription; await refresh() }
    }

    func enqueue(_ item: AudioRecording) {
        guard jobsWritable else { errorMessage = "The saved work list needs recovery before adding jobs. Audio remains available in your recording folder."; return }
        let old = jobs
        if let index = jobs.firstIndex(where: { $0.id == item.id }) {
            guard jobs[index].status != .running else { return }
            jobs[index].status = .queued; jobs[index].error = nil
            jobs[index].audioURL = item.url; jobs[index].title = item.title
        } else { jobs.append(TranscriptionJob(recording: item)) }
        guard persistJobs() else { jobs = old; return }
        if !isShuttingDown { queuePaused = false; processNext() }
    }

    func job(for item: AudioRecording) -> TranscriptionJob? { jobs.first { $0.id == item.id } }

    func retry(_ job: TranscriptionJob) async {
        guard !isShuttingDown else { return }
        await refresh()
        guard !isShuttingDown else { return }
        guard let item = recordings.first(where: { $0.id == job.id }) else {
            errorMessage = "Reconnect the recording drive or restore the audio with its details sidecar, then retry. The existing transcript is safe."
            return
        }
        enqueue(item)
    }

    func resumeQueue() { queuePaused = false; processNext() }

    func pauseQueue() { queuePaused = true; runner?.cancel() }

    func processNext() {
        guard !isShuttingDown, !isProcessing, !queuePaused, jobsWritable, !models.isBusy, models.isReady, let modelFolder = models.modelDirectory,
              let index = jobs.firstIndex(where: { $0.status == .queued }) else { return }
        let job = jobs[index]
        jobs[index].status = .running
        guard persistJobs() else { jobs[index].status = .queued; return }
        isProcessing = true; processingTitle = job.title
        let worker = WorkerProcess(); runner = worker
        processingTask = Task {
            do {
                guard FileManager.default.isReadableFile(atPath: job.audioURL.path) else { throw LocalAudioError.message("The audio file is unavailable. Reconnect its drive or restore the file, then retry.") }
                try await worker.run(executable: WorkerProcess.helperURL(), arguments: ["--input", job.audioURL.path, "--models", modelFolder.path, "--output", AudioRecording.transcriptURL(for: job.audioURL).path], logs: dataFolder.appendingPathComponent("WorkerScratch"))
                let result = try PrivateJSON.read(LocalTranscript.self, from: AudioRecording.transcriptURL(for: job.audioURL))
                guard result.version == 1 else { throw LocalAudioError.message("The local worker produced an unsupported transcript.") }
                jobs.removeAll { $0.id == job.id }
            } catch is CancellationError {
                if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index].status = .queued }
            } catch {
                if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index].status = .failed; jobs[index].error = error.localizedDescription }
            }
            _ = persistJobs(); runner = nil; processingTask = nil; isProcessing = false; processingTitle = ""
            await refresh(); processNext()
        }
    }

    @discardableResult
    private func persistJobs() -> Bool {
        do { try PrivateJSON.write(jobs, to: dataFolder.appendingPathComponent("jobs.json")); return true }
        catch { errorMessage = "The unfinished work list could not be saved: " + error.localizedDescription; return false }
    }

    func exportTranscript() {
        guard let selected, let transcript else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = selected.title + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.resolvingSymlinksInPath() != selected.url.resolvingSymlinksInPath(), url.resolvingSymlinksInPath() != selected.transcriptURL.resolvingSymlinksInPath() else { errorMessage = "Choose a different file so the audio and transcript remain safe."; return }
        do { try transcript.exportedText(title: selected.title, recordedAt: selected.date).write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = error.localizedDescription }
    }

    func prepareToQuit() async {
        isShuttingDown = true
        queuePaused = true
        runner?.cancel()
        models.cancel()
        await capture.stop()
        for task in Array(registrationTasks.values) { await task.value }
        if let importTask { await importTask.value }
        if let processingTask { await processingTask.value }
        await models.cancelAndWait()
        savePreferences()
    }
}

@MainActor
final class PlaybackController: ObservableObject {
    @Published var isPlaying = false
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var error: String?
    @Published var rate: Float = 1 { didSet { audio?.rate = rate } }
    private var audio: AVAudioPlayer?
    private var currentURL: URL?
    private var timer: Timer?
    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    func load(_ item: AudioRecording?) {
        guard currentURL != item?.url else { return }
        pause(); audio = nil; currentURL = item?.url; position = 0; duration = 0; error = nil
        guard let item else { return }
        do { audio = try AVAudioPlayer(contentsOf: item.url); audio?.enableRate = true; audio?.rate = rate; duration = audio?.duration ?? item.duration }
        catch { self.error = "This audio could not be opened for playback: " + error.localizedDescription }
    }
    func play() { guard let audio else { return }; if audio.currentTime >= audio.duration - 0.05 { audio.currentTime = 0 }; isPlaying = audio.play(); if !isPlaying { error = "Playback could not start. Check your Mac's audio output." } }
    func pause() { audio?.pause(); isPlaying = false }
    func toggle() { isPlaying ? pause() : play() }
    func seek(_ seconds: Double) { let time = max(0, min(duration, seconds)); audio?.currentTime = time; position = time }
    func jump(to seconds: Double) { seek(seconds); play() }
    private func tick() { guard let audio else { return }; position = audio.currentTime; isPlaying = audio.isPlaying }
}
