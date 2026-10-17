import AVFoundation
import CoreMedia
import Foundation
import LocalAudioCore

/// The production PCM append/finalize/publish path, independent of microphone
/// discovery and permission. Call append and finish on the supplied queue.
/// AVFoundation objects remain confined there; only value results leave it.
final class PCMRecordingWriter {
    enum Outcome: Sendable {
        // Every outcome except suppressed has claimed the completion gate.
        case saved(URL, TimeInterval)
        case empty
        case failed(String, URL?)
        case suppressed
    }

    let stagingURL: URL
    let publishedURL: URL
    private(set) var progress = CaptureProgress()
    private let completionGate: CaptureCompletionGate
    private let callbackQueue: DispatchQueue
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sourceFormat: CMFormatDescription?
    private var isFinishing = false

    init(stagingURL: URL, publishedURL: URL, completionGate: CaptureCompletionGate, callbackQueue: DispatchQueue) {
        self.stagingURL = stagingURL
        self.publishedURL = publishedURL
        self.completionGate = completionGate
        self.callbackQueue = callbackQueue
    }

    /// Returns true only for the first successfully appended audio buffer.
    @discardableResult
    func append(_ sampleBuffer: CMSampleBuffer) throws -> Bool {
        guard !isFinishing, !completionGate.isCompleted else { throw CaptureFailure("The recording is already stopped or finalizing.") }
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM else {
            throw CaptureFailure("The selected microphone delivered an unsupported or invalid audio buffer.")
        }
        if let sourceFormat, !CFEqual(sourceFormat, format) {
            throw CaptureFailure("The microphone audio format changed during recording. Recording stopped before mixing formats.")
        }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let nextProgress = try progress.appending(frames: Int64(CMSampleBufferGetNumSamples(sampleBuffer)),
            at: CMTimeGetSeconds(timestamp), sampleRate: asbd.mSampleRate)
        if writer == nil {
            let newWriter = try AVAssetWriter(outputURL: stagingURL, fileType: .caf)
            let newInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            newInput.expectsMediaDataInRealTime = true
            guard newWriter.canAdd(newInput) else { throw CaptureFailure("The microphone PCM format cannot be saved as CAF.") }
            newWriter.add(newInput)
            writer = newWriter
            input = newInput
            sourceFormat = format
            guard newWriter.startWriting() else { throw CaptureFailure(newWriter.error?.localizedDescription ?? "The audio file writer could not start.") }
            newWriter.startSession(atSourceTime: timestamp)
        }
        guard let writer, writer.status == .writing, let input else {
            throw CaptureFailure(self.writer?.error?.localizedDescription ?? "The audio writer stopped unexpectedly.")
        }
        guard input.isReadyForMoreMediaData else {
            throw CaptureFailure("The disk could not keep up with the microphone. Recording stopped to avoid silently dropping audio.")
        }
        guard input.append(sampleBuffer) else {
            throw CaptureFailure(writer.error?.localizedDescription ?? "The audio writer rejected a microphone buffer.")
        }
        let first = progress.frames == 0
        progress = nextProgress
        return first
    }

    /// Finish is asynchronous even for an empty recording. A timeout owner may
    /// have claimed the gate independently; late completion then closes the
    /// writer but cannot publish or claim another result. No file is cancelled
    /// or deleted on any failure path.
    func finish(_ completion: @escaping (Outcome) -> Void) {
        guard !isFinishing else {
            callbackQueue.async { completion(.suppressed) }
            return
        }
        isFinishing = true
        callbackQueue.async { [self] in
            guard let writer else {
                report(.empty, completion: completion)
                return
            }
            guard writer.status == .writing else {
                report(.failed(writer.error?.localizedDescription ?? "The audio writer could not finalize the recording.", recoverableURL()), completion: completion)
                return
            }
            input?.markAsFinished()
            writer.finishWriting { [self] in
                callbackQueue.async { [self] in
                    guard !completionGate.isCompleted else { completion(.suppressed); return }
                    guard writer.status == .completed else {
                        report(.failed(writer.error?.localizedDescription ?? "The recording could not be finalized.", recoverableURL()), completion: completion)
                        return
                    }
                    do {
                        let file = try AVAudioFile(forReading: stagingURL)
                        try progress.verify(finalFrames: file.length, sampleRate: file.fileFormat.sampleRate)
                        let values = try stagingURL.resourceValues(forKeys: [.fileSizeKey])
                        guard (values.fileSize ?? 0) > 0 else { throw CaptureFailure("The finalized audio file is empty.") }
                        // Claim only after verification, and before the rename.
                        // A failed rename still owns completion and must report
                        // its failure without attempting a second claim.
                        guard completionGate.claim() else { completion(.suppressed); return }
                        do {
                            try FileManager.default.moveItem(at: stagingURL, to: publishedURL)
                            completion(.saved(publishedURL, progress.elapsed))
                        } catch {
                            completion(.failed("The completed audio could not be moved into the recording library: " + error.localizedDescription, recoverableURL()))
                        }
                    } catch {
                        report(.failed("The saved recording could not be verified: " + error.localizedDescription, recoverableURL()), completion: completion)
                    }
                }
            }
        }
    }

    private func report(_ outcome: Outcome, completion: (Outcome) -> Void) {
        completion(completionGate.claim() ? outcome : .suppressed)
    }

    private func recoverableURL() -> URL? {
        FileManager.default.fileExists(atPath: stagingURL.path) ? stagingURL : nil
    }
}
