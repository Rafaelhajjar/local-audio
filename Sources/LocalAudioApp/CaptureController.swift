import AppKit
import AVFoundation
import Combine
import CoreMedia
import LocalAudioCore

struct AudioInput: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

@MainActor
final class CaptureController: ObservableObject {
    @Published private(set) var devices: [AudioInput] = []
    @Published var selectedDeviceID: String?
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var isFinalizing = false
    @Published private(set) var level: Double = -160
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastError: String?
    var onSaved: ((URL) -> Void)?

    private var backend: CaptureBackend!
    private var activeID: UUID?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    init() {
        backend = CaptureBackend { [weak self] event in
            Task { @MainActor [weak self] in self?.receive(event) }
        }
        refreshInputs()
    }

    func refreshInputs() { backend.refreshInputs() }

    func start(in folder: URL) async {
        guard activeID == nil, !isStarting, !isRecording, !isFinalizing else { return }
        let id = UUID()
        activeID = id
        isStarting = true
        lastError = nil
        level = -160
        elapsed = 0
        let selectedID = selectedDeviceID
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        // Stop may be pressed while the system permission prompt is open.
        guard activeID == id, isStarting else { return }
        guard allowed else {
            receive(.finished(id, .failed("Microphone access is denied. Enable LocalAudio in System Settings → Privacy & Security → Microphone, then try again.", nil)))
            return
        }
        backend.start(id: id, folder: folder, selectedDeviceID: selectedID)
    }

    func stop() async {
        guard let id = activeID else { return }
        if !isFinalizing {
            isRecording = false
            isStarting = false
            isFinalizing = true
            level = -160
            backend.stop(id: id)
        }
        await withCheckedContinuation { stopWaiters.append($0) }
    }

    private func receive(_ event: CaptureEvent) {
        switch event {
        case let .devices(inputs): devices = inputs
        case let .started(id):
            guard id == activeID, !isFinalizing else { return }
            isStarting = false
            isRecording = true
        case let .meter(id, decibels, seconds):
            guard id == activeID, !isFinalizing else { return }
            level = min(0, max(-160, decibels))
            elapsed = seconds
        case let .finalizing(id, reason):
            guard id == activeID else { return }
            isStarting = false
            isRecording = false
            isFinalizing = true
            level = -160
            if let reason { lastError = reason }
        case let .finished(id, result):
            guard id == activeID else { return }
            activeID = nil
            isStarting = false
            isRecording = false
            isFinalizing = false
            level = -160
            switch result {
            case let .saved(url, seconds, warning):
                elapsed = seconds
                lastError = warning
                onSaved?(url)
            case let .cancelled(reason): lastError = reason
            case let .failed(message, recovery):
                lastError = message + recovery.map { " The original file was kept at \($0.path). Import it manually if it can be recovered." }.orEmpty
            }
            let waiters = stopWaiters
            stopWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

private enum CaptureResult: Sendable {
    case saved(URL, TimeInterval, String?)
    case cancelled(String?)
    case failed(String, URL?)
}

private enum CaptureEvent: Sendable {
    case devices([AudioInput])
    case started(UUID)
    case meter(UUID, Double, TimeInterval)
    case finalizing(UUID, String?)
    case finished(UUID, CaptureResult)
}

/// AVCaptureSession is confined to sessionQueue; buffers, writer and run state
/// are confined to audioQueue. Neither queue synchronously waits for the other.
/// Only Sendable value events cross back to the main actor.
private final class CaptureBackend: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let sessionQueue = DispatchQueue(label: "local.audio.capture.session", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "local.audio.capture.writer", qos: .userInitiated)
    private let deadlineQueue = DispatchQueue(label: "local.audio.capture.deadline", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let stopGate = CaptureStopGate()
    private let emit: (CaptureEvent) -> Void
    private var observers: [NSObjectProtocol] = []
    private let operationsLock = NSLock()
    private var operations: [UUID: CaptureOperation] = [:]

    // sessionQueue only
    private var sessionID: UUID?
    private var inputID: String?
    private var activeOutput: AVCaptureAudioDataOutput?
    private var watchdog: DispatchSourceTimer?
    // audioQueue only
    private var run: CaptureRun?

    init(emit: @escaping (CaptureEvent) -> Void) {
        self.emit = emit
        super.init()
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
            let description = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "The microphone capture session failed."
            self?.sessionQueue.async { [weak self] in
                guard let self, let id = self.sessionID else { return }
                self.requestStop(id: id, reason: "Recording stopped: " + description)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] notification in
            let disconnectedID = (notification.object as? AVCaptureDevice)?.uniqueID
            self?.sessionQueue.async { [weak self] in
                guard let self else { return }
                self.discoverInputs()
                guard let id = self.sessionID, disconnectedID == self.inputID else { return }
                self.requestStop(id: id, reason: "The selected microphone disconnected. Recording stopped; choose an available input before starting again.")
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil) { [weak self] _ in
            self?.refreshInputs()
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func refreshInputs() { sessionQueue.async { [weak self] in self?.discoverInputs() } }

    private func audioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    private func discoverInputs() {
        emit(.devices(audioDevices().map { AudioInput(id: $0.uniqueID, name: $0.localizedName) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }))
    }

    private func operation(id: UUID) -> CaptureOperation? {
        operationsLock.lock()
        defer { operationsLock.unlock() }
        return operations[id]
    }

    private func finishClaimed(_ operation: CaptureOperation, result: CaptureResult) {
        operationsLock.lock()
        operations.removeValue(forKey: operation.id)
        operationsLock.unlock()
        emit(.finished(operation.id, result))
    }

    private func finish(_ operation: CaptureOperation, result: CaptureResult) {
        guard operation.completion.claim() else { return }
        finishClaimed(operation, result: result)
    }

    func start(id: UUID, folder: URL, selectedDeviceID: String?) {
        let operation = CaptureOperation(id: id, folder: folder)
        operationsLock.lock()
        operations[id] = operation
        operationsLock.unlock()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.stopGate.isStopped(id) else {
                self.finish(operation, result: .cancelled(nil))
                return
            }
            guard self.sessionID == nil else {
                self.finish(operation, result: .failed("The previous microphone session has not stopped yet. Try again after it closes.", nil))
                return
            }
            do {
                try CaptureDestination.prepare(folder)
                let capacity = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
                try CaptureDestination.requireDiskSpace(availableBytes: capacity)
                let device: AVCaptureDevice?
                if let selectedDeviceID {
                    device = self.audioDevices().first { $0.uniqueID == selectedDeviceID }
                } else {
                    device = AVCaptureDevice.default(for: .audio)
                }
                guard let device else {
                    throw CaptureFailure(selectedDeviceID == nil
                        ? "No system default microphone is available. Connect a microphone and refresh inputs."
                        : "The selected microphone is unavailable. Reconnect it or choose another input; LocalAudio will not switch microphones silently.")
                }
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureAudioDataOutput()
                self.session.beginConfiguration()
                self.session.inputs.forEach { self.session.removeInput($0) }
                self.session.outputs.forEach { self.session.removeOutput($0) }
                guard self.session.canAddInput(input), self.session.canAddOutput(output) else {
                    self.session.commitConfiguration()
                    throw CaptureFailure("This microphone cannot provide an audio capture stream. Choose another input.")
                }
                self.session.addInput(input)
                // Preserve the device's sample rate/channel count while asking
                // AVFoundation for a widely supported PCM representation.
                output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
                output.setSampleBufferDelegate(self, queue: self.audioQueue)
                self.session.addOutput(output)
                self.session.commitConfiguration()
                self.sessionID = id
                self.inputID = device.uniqueID
                self.activeOutput = output
                self.audioQueue.async { [weak self] in
                    guard let self else { return }
                    guard !self.stopGate.isStopped(id) else {
                        self.finish(operation, result: .cancelled(nil))
                        self.sessionQueue.async { [weak self] in self?.stopSession(id: id) }
                        return
                    }
                    self.run = CaptureRun(operation: operation, outputID: ObjectIdentifier(output))
                }
                self.installWatchdog(id: id)
                self.session.startRunning()
                if !self.session.isRunning {
                    self.requestStop(id: id, reason: "The microphone session could not start. Check that the device is available and try again.")
                }
            } catch {
                self.finish(operation, result: .failed("Could not start recording: " + error.localizedDescription, nil))
            }
        }
    }

    func stop(id: UUID) { requestStop(id: id, reason: nil) }

    private func requestStop(id: UUID, reason: String?) {
        let wasAlreadyStopped = stopGate.isStopped(id)
        stopGate.stop(id)
        // Session shutdown and the hard deadline must not wait behind a stuck
        // synchronous AVAssetWriter append on the audio queue.
        sessionQueue.async { [weak self] in self?.stopSession(id: id) }
        guard let operation = operation(id: id) else {
            if !wasAlreadyStopped { emit(.finished(id, .cancelled(reason))) }
            return
        }
        deadlineQueue.asyncAfter(deadline: .now() + 12) { [weak self, operation] in
            guard let self, operation.completion.claim() else { return }
            // No filesystem call on the deadline queue: even a disconnected
            // destination must not turn a bounded Stop into another I/O wait.
            self.finishClaimed(operation, result: .failed("Audio finalization did not finish within 12 seconds. No completed recording was announced. Any incomplete file, if created, remains at \(operation.stagingURL.path) for manual recovery.", nil))
        }
        audioQueue.async { [weak self] in
            guard let self else { return }
            guard let run = self.run, run.id == id else {
                // Start may still be awaiting microphone permission, with no
                // session or file yet. A stop in that state is cancellation.
                self.finish(operation, result: .cancelled(reason))
                return
            }
            if let reason, run.stopReason == nil { run.stopReason = reason }
            guard !run.isFinalizing else { return }
            run.isFinalizing = true
            self.emit(.finalizing(id, run.stopReason))
            // Stop accepting samples before shutting down the session. This
            // allows writer finalization even if a device driver stops slowly.
            self.finalize(run)
        }
    }

    private func stopSession(id: UUID) {
        guard sessionID == id else { return }
        watchdog?.cancel()
        watchdog = nil
        session.stopRunning()
        activeOutput?.setSampleBufferDelegate(nil, queue: nil)
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
        sessionID = nil
        inputID = nil
        activeOutput = nil
    }

    private func installWatchdog(id: UUID) {
        watchdog?.cancel()
        // The audio queue remains responsive even if a device driver blocks
        // the session's synchronous startRunning/stopRunning methods.
        let timer = DispatchSource.makeTimerSource(queue: audioQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, let run = self.run, run.id == id, !run.isFinalizing else { return }
            if ProcessInfo.processInfo.systemUptime - run.lastSampleUptime > 10 {
                self.requestStop(id: id, reason: run.progress.frames == 0
                    ? "The microphone did not deliver audio within 10 seconds. Check the input and start again."
                    : "The microphone stopped delivering audio for 10 seconds. Recording stopped; the captured audio will be saved if valid.")
            }
        }
        watchdog = timer
        timer.resume()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let run, run.outputID == ObjectIdentifier(output), !run.isFinalizing, !stopGate.isStopped(run.id) else { return }
        run.lastSampleUptime = ProcessInfo.processInfo.systemUptime
        do {
            guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
                  let format = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  asbd.mFormatID == kAudioFormatLinearPCM else {
                throw CaptureFailure("The selected microphone delivered an unsupported or invalid audio buffer.")
            }
            if let sourceFormat = run.sourceFormat, !CFEqual(sourceFormat, format) {
                throw CaptureFailure("The microphone audio format changed during recording. Recording stopped before mixing formats.")
            }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let nextProgress = try run.progress.appending(frames: Int64(CMSampleBufferGetNumSamples(sampleBuffer)),
                at: CMTimeGetSeconds(timestamp), sampleRate: asbd.mSampleRate)
            if run.writer == nil {
                let writer = try AVAssetWriter(outputURL: run.url, fileType: .caf)
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else { throw CaptureFailure("The microphone PCM format cannot be saved as CAF.") }
                writer.add(input)
                run.writer = writer
                run.input = input
                run.sourceFormat = format
                guard writer.startWriting() else { throw CaptureFailure(writer.error?.localizedDescription ?? "The audio file writer could not start.") }
                writer.startSession(atSourceTime: timestamp)
            }
            guard let writer = run.writer, writer.status == .writing, let input = run.input else {
                throw CaptureFailure(run.writer?.error?.localizedDescription ?? "The audio writer stopped unexpectedly.")
            }
            guard input.isReadyForMoreMediaData else {
                throw CaptureFailure("The disk could not keep up with the microphone. Recording stopped to avoid silently dropping audio.")
            }
            guard input.append(sampleBuffer) else {
                throw CaptureFailure(writer.error?.localizedDescription ?? "The audio writer rejected a microphone buffer.")
            }
            let wasFirst = run.progress.frames == 0
            run.progress = nextProgress
            if wasFirst { emit(.started(run.id)) }
            if wasFirst || run.lastSampleUptime - run.lastMeterUptime >= 0.1 {
                run.lastMeterUptime = run.lastSampleUptime
                emit(.meter(run.id, peakDB(sampleBuffer, format: asbd), run.progress.elapsed))
            }
        } catch {
            requestStop(id: run.id, reason: "Recording stopped: " + error.localizedDescription)
        }
    }

    private func finalize(_ run: CaptureRun) {
        guard let writer = run.writer else {
            complete(run, result: .cancelled(run.stopReason ?? "No audio was received; no recording was saved."))
            return
        }
        guard writer.status == .writing else {
            complete(run, result: .failed(run.stopReason ?? writer.error?.localizedDescription ?? "The audio writer could not finalize the recording.", recoverableURL(run)))
            return
        }
        run.input?.markAsFinished()
        run.finalizationInFlight = true
        writer.finishWriting { [weak self, run] in
            self?.audioQueue.async { [weak self, run] in
                guard let self else { return }
                run.finalizationInFlight = false
                guard !run.operation.completion.isCompleted else {
                    if self.run === run { self.run = nil }
                    return
                }
                guard writer.status == .completed else {
                    self.complete(run, result: .failed(writer.error?.localizedDescription ?? run.stopReason ?? "The recording could not be finalized.", self.recoverableURL(run)))
                    return
                }
                do {
                    let file = try AVAudioFile(forReading: run.url)
                    try run.progress.verify(finalFrames: file.length, sampleRate: file.fileFormat.sampleRate)
                    let values = try run.url.resourceValues(forKeys: [.fileSizeKey])
                    guard (values.fileSize ?? 0) > 0 else { throw CaptureFailure("The finalized audio file is empty.") }
                    // Claim completion before the rename so a timeout cannot
                    // concurrently report the staging path while it publishes.
                    guard run.operation.completion.claim() else {
                        if self.run === run { self.run = nil }
                        return
                    }
                    // Same-folder rename publishes only verified complete audio.
                    // A UUID destination is never overwritten.
                    let result: CaptureResult
                    do {
                        try FileManager.default.moveItem(at: run.url, to: run.publishedURL)
                        result = .saved(run.publishedURL, run.progress.elapsed, run.stopReason)
                    } catch {
                        result = .failed("The completed audio could not be moved into the recording library: " + error.localizedDescription, self.recoverableURL(run))
                    }
                    if self.run === run { self.run = nil }
                    self.finishClaimed(run.operation, result: result)
                } catch {
                    self.complete(run, result: .failed("The saved recording could not be verified: " + error.localizedDescription, self.recoverableURL(run)))
                }
            }
        }
    }

    private func recoverableURL(_ run: CaptureRun) -> URL? {
        guard FileManager.default.fileExists(atPath: run.url.path) else { return nil }
        // Never cancel, delete or rename failed/in-flight original audio.
        // The hidden staging name explicitly identifies it as incomplete.
        return run.url
    }

    private func complete(_ run: CaptureRun, result: CaptureResult) {
        if self.run === run { self.run = nil }
        finish(run.operation, result: result)
    }

    private func peakDB(_ sampleBuffer: CMSampleBuffer, format: AudioStreamBasicDescription) -> Double {
        let encoding: PCMLevelEncoding
        let bigEndian = format.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        if format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            encoding = .floatingPoint(bits: Int(format.mBitsPerChannel), bigEndian: bigEndian)
        } else if format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
            encoding = .signedInteger(bits: Int(format.mBitsPerChannel), bigEndian: bigEndian)
        } else { return -160 }
        var requiredSize = 0
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard requiredSize >= MemoryLayout<AudioBufferList>.size else { return -160 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: requiredSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: list, bufferListSize: requiredSize, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &retainedBuffer) == noErr else { return -160 }
        var peak = -160.0
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            guard let bytes = buffer.mData else { continue }
            peak = max(peak, PCMLevelMeter.peakDB(in: Data(bytes: bytes, count: Int(buffer.mDataByteSize)), encoding: encoding))
        }
        return peak
    }
}

/// Mutable only on the backend's audioQueue; never sent to the main actor.
private final class CaptureRun {
    let operation: CaptureOperation
    var id: UUID { operation.id }
    var url: URL { operation.stagingURL }
    var publishedURL: URL { operation.publishedURL }
    let outputID: ObjectIdentifier
    var writer: AVAssetWriter?
    var input: AVAssetWriterInput?
    var sourceFormat: CMFormatDescription?
    var progress = CaptureProgress()
    var isFinalizing = false
    var finalizationInFlight = false
    var stopReason: String?
    var lastSampleUptime = ProcessInfo.processInfo.systemUptime
    var lastMeterUptime = 0.0

    init(operation: CaptureOperation, outputID: ObjectIdentifier) { self.operation = operation; self.outputID = outputID }
}

private final class CaptureOperation {
    let id: UUID
    let stagingURL: URL
    let publishedURL: URL
    let completion = CaptureCompletionGate()
    init(id: UUID, folder: URL) {
        self.id = id
        stagingURL = CaptureDestination.stagingURL(in: folder, identifier: id)
        publishedURL = CaptureDestination.uniqueURL(in: folder, identifier: id)
    }
}
