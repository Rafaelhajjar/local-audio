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
    var quickStartCompleted: Bool?
    var microphonePolicy: MicrophonePolicy?
    var retention: AudioRetention?
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
    @Published var showQuickStart = false
    @Published private(set) var lastSavedRecording: AudioRecording?
    @Published private(set) var interruptedRecordings: [URL] = []
    @Published var microphonePolicy: MicrophonePolicy
    @Published private(set) var automaticRecordingArmed = false
    @Published private(set) var retention: AudioRetention?
    @Published private(set) var isManagingAudio = false
    @Published var storageStatus: String?
    private var maintenanceTimer: Timer?
    private var automationWorking = false
    private var automation = MicrophoneAutomation()
    private var automaticInputID: String?
    private var lastRetentionCheck = Date.distantPast
    let models: ModelManager
    let voices: VoiceController
    let capture = CaptureController()
    let player = PlaybackController()
    let dataFolder: URL
    private var library: RecordingLibrary
    private var preferences: AppPreferences
    private var runner: WorkerProcess?
    private var processingTask: Task<Void, Never>?
    private var audioManagementTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var registrationTasks: [UUID: Task<Void, Never>] = [:]
    private var jobsWritable = true
    private var preferencesWritable = true
    private var hasStarted = false
    private var latestScanID = UUID()
    private var presentationUpdates = Set<AnyCancellable>()

    var canManageAudio: Bool { !isShuttingDown && !isManagingAudio && !isImporting && !isProcessing && !voices.isBusy && registrationTasks.isEmpty }
    var selected: AudioRecording? { recordings.first { $0.id == selection } }
    var pendingCount: Int { jobs.filter { $0.status != .failed }.count }
    var canChangeFolder: Bool { !isShuttingDown && !isManagingAudio && !automaticRecordingArmed && !capture.isRecording && !capture.isStarting && !capture.isFinalizing && !isProcessing && !isImporting && !voices.isBusy && registrationTasks.isEmpty }

    func startRecording() async {
        automaticRecordingArmed = false
        await beginCapture()
    }

    private func beginCapture() async {
        guard !isShuttingDown, !capture.isBusy else { return }
        guard let input = microphonePolicy.resolve(devices: capture.devices, selectedID: capture.selectedDeviceID, defaultID: capture.defaultDeviceID) else {
            errorMessage = "Connect an allowed microphone. The Mac microphone will not be used as a fallback."
            return
        }
        player.pause()
        automaticInputID = automaticRecordingArmed ? input.id : nil
        await capture.start(in: recordingsFolder, deviceID: input.id)
    }

    func stopRecording() async {
        automaticRecordingArmed = false
        await capture.stop()
    }

    func setMicrophonePolicy(_ policy: MicrophonePolicy) {
        guard !capture.isBusy else { return }
        automaticRecordingArmed = false
        microphonePolicy = policy; savePreferences()
    }

    func toggleAutomaticRecording() {
        guard microphonePolicy.mode != .manual, !showQuickStart else { return }
        automation = MicrophoneAutomation()
        automaticRecordingArmed.toggle()
        if !automaticRecordingArmed { Task { await capture.stop() } }
        else { Task { await maintain() } }
    }

    private func maintain() async {
        guard !isShuttingDown, !automationWorking else { return }
        automationWorking = true
        defer { automationWorking = false }
        if automaticRecordingArmed, !showQuickStart {
            automation.connected(capture.devices)
            if !capture.isBusy {
                let available = automation.available(capture.devices)
                if let input = microphonePolicy.resolve(devices: available, selectedID: nil, defaultID: nil) {
                    player.pause(); automaticInputID = input.id
                    await capture.start(in: recordingsFolder, deviceID: input.id)
                }
            } else if capture.isRecording, capture.elapsed >= 30 * 60 {
                await capture.stop()
            }
        }
        if Date().timeIntervalSince(lastRetentionCheck) >= 3600 {
            lastRetentionCheck = Date()
            await cleanUpAudio()
        }
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
        microphonePolicy = preferences.microphonePolicy ?? MicrophonePolicy()
        retention = preferences.retention
        self.preferences = preferences
        recordingsFolder = preferences.recordingsFolder
        automaticallyTranscribe = preferences.automaticallyTranscribe
        library = RecordingLibrary(folder: preferences.recordingsFolder)
        let logs = paths.data.appendingPathComponent("WorkerScratch")
        let helper = WorkerProcess.helperURL()
        models = ModelManager(storageDirectory: paths.data.appendingPathComponent("Models"), validator: { folder in
            try await WorkerProcess.validate(executable: helper, modelFolder: folder, logs: logs)
        })
        voices = VoiceController(dataFolder: paths.data)
        let jobsURL = paths.data.appendingPathComponent("jobs.json")
        if FileManager.default.fileExists(atPath: jobsURL.path) {
            do {
                jobs = try PrivateJSON.read([TranscriptionJob].self, from: jobsURL)
                for index in jobs.indices where jobs[index].status == .running { jobs[index].status = .queued }
            } catch { initialError = "The unfinished transcription list could not be read and has been preserved. " + error.localizedDescription; jobsWritable = false }
        }
        capture.selectedDeviceID = preferences.inputID
        capture.onFinished = { [weak self] in
            guard let self else { return }
            if self.capture.lastError != nil, let id = self.automaticInputID { self.automation.failed(id) }
            self.automaticInputID = nil
        }
        capture.onSaved = { [weak self] url in
            guard let self else { return }
            let id = UUID()
            self.registrationTasks[id] = Task { @MainActor in
                await self.recordingSaved(url)
                self.registrationTasks[id] = nil
            }
        }
        capture.onUnsuccessfulFinish = { [weak self] in Task { await self?.refresh() } }
        errorMessage = initialError
        voices.canAnalyze = { [weak self] in self?.isProcessing == false && self?.isShuttingDown == false && self?.isManagingAudio == false }
        voices.onWorkFinished = { [weak self] in self?.processNext() }
        voices.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &presentationUpdates)
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
        async let voiceSetup: Void = voices.start()
        await models.refresh()
        await scan
        await voiceSetup
        if preferences.quickStartCompleted != true, recordings.isEmpty, errorMessage == nil, !capture.isBusy {
            showQuickStart = true
        }
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.maintain() }
        }
        processNext()
        await cleanUpAudio()
    }

    func finishQuickStart() {
        guard !capture.isBusy else { return }
        preferences.quickStartCompleted = true
        showQuickStart = false
        player.pause()
        savePreferences()
    }

    func refresh() async {
        let requestedLibrary = library
        let scanID = UUID(); latestScanID = scanID
        isLibraryLoading = true
        defer { if latestScanID == scanID { isLibraryLoading = false } }
        do {
            let scan = try await requestedLibrary.scanWithWarnings()
            let interrupted = try await requestedLibrary.interruptedRecordingURLs()
            guard library === requestedLibrary, latestScanID == scanID else { return }
            recordings = scan.recordings; libraryWarnings = scan.warnings
            interruptedRecordings = interrupted
            if !recordings.contains(where: { $0.id == selection }) { selection = recordings.first?.id }
            await loadSelection()
        } catch { if library === requestedLibrary { errorMessage = error.localizedDescription } }
    }

    func loadSelection() async {
        player.load(selected)
        transcript = nil; transcriptError = nil
        if let selected {
            titleDraft = selected.title; dateDraft = selected.date
            if FileManager.default.fileExists(atPath: selected.transcriptURL.path) {
                do {
                    let loaded = try PrivateJSON.read(LocalTranscript.self, from: selected.transcriptURL)
                    guard loaded.version == 1 else { throw LocalAudioError.message("This transcript needs a newer LocalAudio version.") }
                    transcript = loaded
                } catch { transcriptError = "This transcript could not be read. It has not been changed. " + error.localizedDescription }
            }
        }
        await voices.select(selected)
    }

    func saveDetails() async {
        guard let selected, !isManagingAudio else { return }
        do { try await library.update(selected, title: titleDraft, date: dateDraft); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func savePreferences() {
        preferences.microphonePolicy = microphonePolicy
        preferences.retention = retention
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
        recordingsFolder = folder; library = RecordingLibrary(folder: folder); selection = nil; player.pause()
        if let retention { self.retention = AudioRetention(days: retention.days) }
        savePreferences()
        Task { await refresh() }
    }

    func importFiles() {
        guard !isShuttingDown, !isManagingAudio, !isLibraryLoading, !isImporting else { return }
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
            lastSavedRecording = item
            if automaticallyTranscribe { enqueue(item) }
        } catch { errorMessage = "Audio was saved, but its details could not be registered: " + error.localizedDescription; await refresh() }
    }

    func enqueue(_ item: AudioRecording) {
        guard item.hasAudio, !isManagingAudio else { return }
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
        guard !isShuttingDown, !isManagingAudio, !isProcessing, processingTask == nil, !voices.isBusy, !queuePaused, jobsWritable, !models.isBusy, models.isReady, let modelFolder = models.modelDirectory,
              let index = jobs.firstIndex(where: { $0.status == .queued }) else { return }
        let job = jobs[index]
        jobs[index].status = .running
        guard persistJobs() else { jobs[index].status = .queued; return }
        isProcessing = true; processingTitle = job.title
        let worker = WorkerProcess(); runner = worker
        processingTask = Task {
            var completed = false
            do {
                guard FileManager.default.isReadableFile(atPath: job.audioURL.path) else { throw LocalAudioError.message("The audio file is unavailable. Reconnect its drive or restore the file, then retry.") }
                try await worker.run(executable: WorkerProcess.helperURL(), arguments: ["--input", job.audioURL.path, "--models", modelFolder.path, "--output", AudioRecording.transcriptURL(for: job.audioURL).path], logs: dataFolder.appendingPathComponent("WorkerScratch"))
                let result = try PrivateJSON.read(LocalTranscript.self, from: AudioRecording.transcriptURL(for: job.audioURL))
                guard result.version == 1 else { throw LocalAudioError.message("The local worker produced an unsupported transcript.") }
                jobs.removeAll { $0.id == job.id }
                completed = true
            } catch is CancellationError {
                if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index].status = .queued }
            } catch {
                if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index].status = .failed; jobs[index].error = error.localizedDescription }
            }
            _ = persistJobs(); runner = nil; isProcessing = false; processingTitle = ""
            await refresh()
            if completed, !isShuttingDown, !queuePaused, voices.models.isReady,
               let item = recordings.first(where: { $0.id == job.id }) { await voices.analyze(item) }
            processingTask = nil
            processNext()
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
        let protectedURLs = [selected.url, selected.transcriptURL, AudioRecording.metadataURL(for: selected.url), VoiceLibrary.analysisURL(for: selected.url)]
        guard !protectedURLs.contains(where: { $0.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) else { errorMessage = "Choose a different file so the audio and its sidecars remain safe."; return }
        Task {
            do {
                let text = try await voices.validatedExportedText(transcript, item: selected)
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func setRetention(days: Int?) {
        retention = days.map { AudioRetention(days: $0) }
        savePreferences()
        storageStatus = days == nil ? "Automatic cleanup is off." : "Cleanup enabled. Existing audio gets a fresh \(days!) days before it can expire."
    }

    private func protectedAudioIDs() async throws -> Set<String> {
        guard jobsWritable, preferencesWritable else { throw LocalAudioError.message("Recover saved settings and unfinished work before cleaning audio.") }
        return try await voices.protectedRecordingIDs().union(Set(jobs.map(\.id)))
    }

    func setVaulted(_ item: AudioRecording, _ value: Bool) async {
        await manageAudio {
            try await self.library.setVaulted(item, value)
        }
    }

    func savePassage(_ item: AudioRecording, start: Double, end: Double, title: String) async {
        await manageAudio {
            let clip = try await self.library.savePassage(item, start: start, end: end, title: title)
            self.storageStatus = "Passage saved permanently in the vault."
            await self.refresh(); self.selection = clip.id; await self.loadSelection()
        }
    }

    func removeAudio(_ item: AudioRecording) async {
        await manageAudio {
            let protected = try await self.protectedAudioIDs()
            if self.selected?.id == item.id { self.player.pause() }
            try await self.library.trashAudio(item, protectedIDs: protected)
            self.storageStatus = "Audio moved to Trash. Transcript kept."
        }
    }

    func restoreAudio(_ item: AudioRecording) async {
        await manageAudio {
            try await self.library.restoreAudio(item)
            self.storageStatus = "Audio restored. Its retention window starts again today."
        }
    }

    func cleanUpAudio() async {
        guard let retention else { return }
        await manageAudio {
            let protected = try await self.protectedAudioIDs()
            try await self.library.adoptAudioForRetention()
            let candidates = try await self.library.scan().filter { retention.isDue($0) && !protected.contains($0.id) }
            var removed = 0
            for item in candidates {
                if self.selected?.id == item.id && self.player.isPlaying { continue }
                // Missing, corrupt and future-version transcripts preserve audio.
                guard let text = try? PrivateJSON.read(LocalTranscript.self, from: item.transcriptURL), text.version == 1 else { continue }
                try await self.library.trashAudio(item, protectedIDs: protected)
                removed += 1
            }
            self.storageStatus = "Cleanup complete: \(removed) audio file(s) moved to Trash. Text and vault audio kept."
        }
    }

    private func manageAudio(_ operation: @escaping @MainActor () async throws -> Void) async {
        guard canManageAudio else { return }
        isManagingAudio = true
        let task = Task { @MainActor in
            do { try await operation() } catch { self.errorMessage = error.localizedDescription }
            await self.refresh()
            self.isManagingAudio = false
        }
        audioManagementTask = task
        await task.value
        audioManagementTask = nil
        processNext()
    }

    func prepareToQuit() async {
        isShuttingDown = true
        automaticRecordingArmed = false
        maintenanceTimer?.invalidate()
        queuePaused = true
        runner?.cancel()
        models.cancel()
        voices.beginShutdown()
        await capture.stop()
        for task in Array(registrationTasks.values) { await task.value }
        if let audioManagementTask { await audioManagementTask.value }
        if let importTask { await importTask.value }
        if let processingTask { await processingTask.value }
        await models.cancelAndWait()
        await voices.shutdownAndWait()
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
    private var playbackEnd: Double?
    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    func load(_ item: AudioRecording?) {
        guard currentURL != item?.url || (audio != nil) != (item?.hasAudio == true) else { return }
        pause(); audio = nil; currentURL = item?.url; position = 0; duration = 0; error = nil
        guard let item, item.hasAudio else { return }
        do { audio = try AVAudioPlayer(contentsOf: item.url); audio?.enableRate = true; audio?.rate = rate; duration = audio?.duration ?? item.duration }
        catch { self.error = "This audio could not be opened for playback: " + error.localizedDescription }
    }
    func play() { playbackEnd = nil; startPlayback() }
    private func startPlayback() { guard let audio else { return }; if audio.currentTime >= audio.duration - 0.05 { audio.currentTime = 0 }; isPlaying = audio.play(); if !isPlaying { error = "Playback could not start. Check your Mac's audio output." } }
    func pause() { audio?.pause(); isPlaying = false; playbackEnd = nil }
    func toggle() { isPlaying ? pause() : play() }
    func seek(_ seconds: Double) { playbackEnd = nil; let time = max(0, min(duration, seconds)); audio?.currentTime = time; position = time }
    func jump(to seconds: Double) { seek(seconds); play() }
    func playClip(start: Double, end: Double) {
        guard start.isFinite, end.isFinite, end > start else { return }
        seek(start); playbackEnd = min(duration, end); startPlayback()
    }
    private func tick() {
        guard let audio else { return }
        if let end = playbackEnd, audio.currentTime >= end { audio.currentTime = end; pause() }
        position = audio.currentTime; isPlaying = audio.isPlaying
    }
}
