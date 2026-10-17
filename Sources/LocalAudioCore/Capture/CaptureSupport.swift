import Foundation
import Synchronization

public struct CaptureFailure: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Counts only successfully appended PCM frames. This is also the independent
/// expectation used when reopening the completed CAF before announcing a save.
public struct CaptureProgress: Equatable, Sendable {
    public private(set) var frames: Int64 = 0
    public private(set) var sampleRate: Double = 0
    public private(set) var lastPresentationTime: Double?
    public var elapsed: TimeInterval { sampleRate > 0 ? Double(frames) / sampleRate : 0 }

    public init() {}

    public func appending(frames count: Int64, at presentationTime: Double, sampleRate newRate: Double) throws -> CaptureProgress {
        guard count > 0, presentationTime.isFinite, newRate.isFinite, newRate > 0 else {
            throw CaptureFailure("The microphone delivered invalid PCM timing or an empty audio buffer.")
        }
        guard sampleRate == 0 || abs(sampleRate - newRate) < 0.01 else {
            throw CaptureFailure("The microphone sample rate changed during recording. The recording was stopped.")
        }
        if let previous = lastPresentationTime, presentationTime <= previous {
            throw CaptureFailure("The microphone audio timestamp moved backwards or repeated. The recording was stopped.")
        }
        let (total, overflow) = frames.addingReportingOverflow(count)
        guard !overflow else { throw CaptureFailure("The recording exceeded the supported PCM frame count.") }
        var next = self
        next.frames = total
        next.sampleRate = newRate
        next.lastPresentationTime = presentationTime
        return next
    }

    public func verify(finalFrames: Int64, sampleRate finalRate: Double) throws {
        guard frames > 0, finalFrames > 0 else { throw CaptureFailure("No audio frames were saved.") }
        guard finalFrames == frames else {
            throw CaptureFailure("The saved audio has \(finalFrames) frames; \(frames) were captured. The file was kept for recovery.")
        }
        guard finalRate.isFinite, abs(sampleRate - finalRate) < 0.01 else {
            throw CaptureFailure("The saved audio sample rate does not match the captured audio. The file was kept for recovery.")
        }
    }
}

public enum CaptureDestination {
    public static func stagingURL(in folder: URL, identifier: UUID) -> URL {
        folder.appendingPathComponent(".recording-" + identifier.uuidString + ".incomplete.caf")
    }

    /// A UUID prevents collisions even during rapid Stop/Start or clock changes.
    public static func uniqueURL(in folder: URL, date: Date = Date(), identifier: UUID = UUID()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return folder.appendingPathComponent("LocalAudio-" + formatter.string(from: date) + "-" + identifier.uuidString + ".caf")
    }

    /// Run on a worker queue. An actual exclusive probe detects unwritable or
    /// file-valued destinations before microphone capture begins.
    public static func prepare(_ folder: URL, fileManager: FileManager = .default) throws {
        guard folder.isFileURL else { throw CaptureFailure("Choose a local recordings folder.") }
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CaptureFailure("The recording destination is not a folder.")
            }
            let probe = folder.appendingPathComponent(".local-audio-write-test-" + UUID().uuidString)
            defer { try? fileManager.removeItem(at: probe) }
            try Data([0]).write(to: probe, options: .withoutOverwriting)
        } catch {
            throw CaptureFailure("Cannot write to the recordings folder: \(error.localizedDescription)")
        }
    }

    public static func requireDiskSpace(availableBytes: Int64?, minimumBytes: Int64 = 16 * 1_024 * 1_024) throws {
        if let availableBytes, availableBytes < minimumBytes {
            throw CaptureFailure("The recordings disk is nearly full. Free at least \(minimumBytes / 1_024 / 1_024) MB before recording.")
        }
    }
}

/// Stop can arrive while permission or device configuration is still pending.
/// Remember that intent across both backend queues without sharing AV objects.
public final class CaptureStopGate: Sendable {
    private let stopped = Mutex<Set<UUID>>([])
    public init() {}
    public func stop(_ identifier: UUID) {
        stopped.withLock { _ = $0.insert(identifier) }
    }
    public func isStopped(_ identifier: UUID) -> Bool {
        stopped.withLock { $0.contains(identifier) }
    }
}

/// An independent deadline and a late writer callback may race. Exactly one
/// owns publication/completion, without marking AVFoundation objects Sendable.
public final class CaptureCompletionGate: Sendable {
    private let completed = Mutex(false)
    public init() {}
    public var isCompleted: Bool { completed.withLock { $0 } }
    public func claim() -> Bool {
        completed.withLock { complete in
            guard !complete else { return false }
            complete = true
            return true
        }
    }
}

public enum PCMLevelEncoding: Sendable {
    case signedInteger(bits: Int, bigEndian: Bool)
    case floatingPoint(bits: Int, bigEndian: Bool)
}

public enum PCMLevelMeter {
    /// Handles interleaved or individual channel buffers equally. No signal
    /// threshold controls recording; this value is presentation-only.
    public static func peakDB(in data: Data, encoding: PCMLevelEncoding) -> Double {
        var peak = 0.0
        data.withUnsafeBytes { raw in
            func integer(_ offset: Int, bytes: Int, bigEndian: Bool) -> UInt64 {
                var value: UInt64 = 0
                for index in 0..<bytes {
                    let shift = (bigEndian ? bytes - index - 1 : index) * 8
                    value |= UInt64(raw[offset + index]) << shift
                }
                return value
            }
            switch encoding {
            case let .signedInteger(bits, bigEndian) where [8, 16, 24, 32].contains(bits):
                let width = bits / 8
                for offset in stride(from: 0, through: max(-1, raw.count - width), by: width) {
                    let unsigned = integer(offset, bytes: width, bigEndian: bigEndian)
                    let sign = UInt64(1) << (bits - 1)
                    let signed = unsigned & sign == 0 ? Double(unsigned) : Double(unsigned) - pow(2, Double(bits))
                    peak = max(peak, abs(signed) / pow(2, Double(bits - 1)))
                }
            case let .floatingPoint(bits, bigEndian) where bits == 32 || bits == 64:
                let width = bits / 8
                for offset in stride(from: 0, through: max(-1, raw.count - width), by: width) {
                    let unsigned = integer(offset, bytes: width, bigEndian: bigEndian)
                    let value = bits == 32 ? Double(Float(bitPattern: UInt32(unsigned))) : Double(bitPattern: unsigned)
                    if value.isFinite { peak = max(peak, abs(value)) }
                }
            default: break
            }
        }
        guard peak > 0 else { return -160 }
        return min(0, max(-160, 20 * log10(peak)))
    }
}
