import Foundation
import Darwin
import LocalAudioCore

@MainActor
final class WorkerProcess {
    private var process: Process?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var cancelled = false
    private var timedOut = false
    private var logURL: URL?
    private var logHandle: FileHandle?

    static func helperURL() -> URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/local-audio-transcriber") }

    static func validate(executable: URL, modelFolder: URL, logs: URL) async throws {
        let worker = WorkerProcess()
        try await worker.run(executable: executable, arguments: ["--validate-model", modelFolder.path], logs: logs, timeout: 180)
    }

    func run(executable: URL, arguments: [String], logs: URL, timeout: TimeInterval = 3600) async throws {
        if cancelled { throw CancellationError() }
        guard process == nil else { throw LocalAudioError.message("A local worker is already running.") }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw LocalAudioError.message("The local transcription helper is missing. Reinstall LocalAudio from a complete app download.") }
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let logURL = logs.appendingPathComponent("worker-" + UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: logURL)
        self.logURL = logURL; logHandle = handle; timedOut = false
        let child = Process(); child.executableURL = executable; child.arguments = arguments
        child.standardOutput = handle; child.standardError = handle; child.qualityOfService = .utility
        process = child
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                child.terminationHandler = { [weak self] ended in
                    let status = ended.terminationStatus
                    Task { @MainActor in self?.finish(status: status) }
                }
                do {
                    try child.run()
                    timeoutTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        guard !Task.isCancelled, let self, self.process?.isRunning == true else { return }
                        self.timedOut = true; self.terminate()
                    }
                } catch { self.finish(error: error) }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    func cancel() { cancelled = true; terminate() }

    private func terminate() {
        guard let child = process, child.isRunning else { return }
        child.terminate()
        Task { [weak self, weak child] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, let child, self.process === child, child.isRunning else { return }
            kill(child.processIdentifier, SIGKILL)
        }
    }

    private func finish(status: Int32 = 1, error: Error? = nil) {
        guard let continuation else { return }
        self.continuation = nil; timeoutTask?.cancel(); timeoutTask = nil
        try? logHandle?.close(); logHandle = nil
        let text = logURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        if let logURL { try? FileManager.default.removeItem(at: logURL) }
        process = nil; logURL = nil
        if let error { continuation.resume(throwing: error) }
        else if cancelled { continuation.resume(throwing: CancellationError()) }
        else if timedOut { continuation.resume(throwing: LocalAudioError.message("Local transcription took too long and was stopped. Your audio and earlier transcript are safe. Try again with a shorter recording.")) }
        else if status != 0 {
            let message = text.split(separator: "\n").last.map(String.init) ?? "The local worker could not finish."
            continuation.resume(throwing: LocalAudioError.message(String(message.prefix(1600))))
        } else { continuation.resume() }
    }
}
