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
    @Published private(set) var signal = CaptureSignal()
    @Published private(set) var defaultDeviceID: String?
    @Published private(set) var lastSavedURL: URL?
    @Published private(set) var lastInputName: String?
    var onSaved: ((URL) -> Void)?
    var onUnsuccessfulFinish: (() -> Void)?

    var isBusy: Bool { isRecording || isStarting || isFinalizing }
    var microphoneAccessDenied: Bool {
        [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio))
    }
    var selectedInputName: String {
        let id = selectedDeviceID ?? defaultDeviceID
        return devices.first { $0.id == id }?.name ?? (selectedDeviceID == nil ? "System default" : "Unavailable microphone")
    }

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
        signal = CaptureSignal()
        lastSavedURL = nil
        lastInputName = nil
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
        case let .devices(inputs, defaultID): devices = inputs; defaultDeviceID = defaultID
        case let .started(id, inputName):
            guard id == activeID, !isFinalizing else { return }
            lastInputName = inputName
            isStarting = false
            isRecording = true
        case let .meter(id, decibels, seconds):
            guard id == activeID, !isFinalizing else { return }
            level = min(0, max(-160, decibels))
            elapsed = seconds
            signal.observe(decibels: decibels, elapsed: seconds)
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
                lastSavedURL = url
                onSaved?(url)
            case let .cancelled(reason): lastError = reason; onUnsuccessfulFinish?()
            case let .failed(message, recovery):
                lastError = message + recovery.map { " The original file was kept at \($0.path). Import it manually if it can be recovered." }.orEmpty
                onUnsuccessfulFinish?()
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
    case devices([AudioInput], String?)
    case started(UUID, String)
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
    private let diskQueue = DispatchQueue(label: "local.audio.capture.disk", qos: .utility)
    private let session = AVCaptureSession()
    private let stopGate = CaptureStopGate()
    private let emit: (CaptureEvent) -> Void
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private let operationsLock = NSLock()
    private var operations: [UUID: CaptureOperation] = [:]

    // sessionQueue only
    private var sessionID: UUID?
    private var inputID: String?
    private var activeOutput: AVCaptureAudioDataOutput?
    private var watchdog: DispatchSourceTimer?
    private var diskMonitor: DispatchSourceTimer?
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
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.stopAll(reason: "The microphone session was interrupted. Recording stopped; the captured audio will be saved if valid.")
        })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.stopAll(reason: "Your Mac is going to sleep. Recording stopped; check the saved audio after waking. Start a new recording to continue.")
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    private func stopAll(reason: String) {
        operationsLock.lock()
        let ids = Array(operations.keys)
        operationsLock.unlock()
        for id in ids { requestStop(id: id, reason: reason) }
    }

    func refreshInputs() { sessionQueue.async { [weak self] in self?.discoverInputs() } }

    private func audioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    private func discoverInputs() {
        emit(.devices(audioDevices().map { AudioInput(id: $0.uniqueID, name: $0.localizedName) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, AVCaptureDevice.default(for: .audio)?.uniqueID))
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
                let capacity = try? CaptureDiskPolicy.availableCapacity(at: folder)
                try CaptureDestination.requireDiskSpace(availableBytes: capacity, minimumBytes: CaptureDiskPolicy.reserveBytes)
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
                let inputName = device.localizedName
                self.audioQueue.async { [weak self] in
                    guard let self else { return }
                    guard !self.stopGate.isStopped(id) else {
                        self.finish(operation, result: .cancelled(nil))
                        self.sessionQueue.async { [weak self] in self?.stopSession(id: id) }
                        return
                    }
                    self.run = CaptureRun(operation: operation, outputID: ObjectIdentifier(output), inputName: inputName, callbackQueue: self.audioQueue)
                }
                self.installWatchdog(id: id)
                self.installDiskMonitor(operation: operation, folder: folder)
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
        diskMonitor?.cancel()
        diskMonitor = nil
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

    private func installDiskMonitor(operation: CaptureOperation, folder: URL) {
        diskMonitor?.cancel()
        // Capacity reads may block on a disconnected drive. Keep them off both
        // capture queues and the independent finalization deadline queue.
        let timer = DispatchSource.makeTimerSource(queue: diskQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self, operation] in
            guard let self, !operation.completion.isCompleted, !self.stopGate.isStopped(operation.id) else { return }
            let capacity = try? CaptureDiskPolicy.availableCapacity(at: folder)
            if let reason = CaptureDiskPolicy.stopReason(availableBytes: capacity) {
                self.requestStop(id: operation.id, reason: reason)
            }
        }
        diskMonitor = timer
        timer.resume()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let run, run.outputID == ObjectIdentifier(output), !run.isFinalizing, !stopGate.isStopped(run.id) else { return }
        run.lastSampleUptime = ProcessInfo.processInfo.systemUptime
        do {
            let wasFirst = try run.writer.append(sampleBuffer)
            if wasFirst { emit(.started(run.id, run.inputName)) }
            if wasFirst || run.lastSampleUptime - run.lastMeterUptime >= 0.1 {
                run.lastMeterUptime = run.lastSampleUptime
                let level: Double
                if let format = CMSampleBufferGetFormatDescription(sampleBuffer),
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                    level = peakDB(sampleBuffer, format: asbd)
                } else { level = -160 }
                emit(.meter(run.id, level, run.progress.elapsed))
            }
        } catch {
            requestStop(id: run.id, reason: "Recording stopped: " + error.localizedDescription)
        }
    }

    private func finalize(_ run: CaptureRun) {
        run.writer.finish { [weak self, run] outcome in
            guard let self else { return }
            if self.run === run { self.run = nil }
            switch outcome {
            case let .saved(url, elapsed):
                self.finishClaimed(run.operation, result: .saved(url, elapsed, run.stopReason))
            case .empty:
                self.finishClaimed(run.operation, result: .cancelled(run.stopReason ?? "No audio was received; no recording was saved."))
            case let .failed(message, recovery):
                let detail = run.stopReason.map { $0 + " " + message } ?? message
                self.finishClaimed(run.operation, result: .failed(detail, recovery))
            case .suppressed:
                // The independent deadline already reported completion. The
                // writer closed its staging file without publishing it.
                break
            }
        }
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
    let outputID: ObjectIdentifier
    let inputName: String
    let writer: PCMRecordingWriter
    var progress: CaptureProgress { writer.progress }
    var isFinalizing = false
    var stopReason: String?
    var lastSampleUptime = ProcessInfo.processInfo.systemUptime
    var lastMeterUptime = 0.0

    init(operation: CaptureOperation, outputID: ObjectIdentifier, inputName: String, callbackQueue: DispatchQueue) {
        self.operation = operation
        self.outputID = outputID
        self.inputName = inputName
        writer = PCMRecordingWriter(stagingURL: operation.stagingURL, publishedURL: operation.publishedURL,
            completionGate: operation.completion, callbackQueue: callbackQueue)
    }
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
