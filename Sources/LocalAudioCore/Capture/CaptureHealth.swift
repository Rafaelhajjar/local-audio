import Foundation

/// A level hint is never evidence of speech, and never decides whether to save.
public struct CaptureSignal: Equatable, Sendable {
    public private(set) var peakDB = -160.0
    public private(set) var elapsed = 0.0
    public init() {}
    public mutating func observe(decibels: Double, elapsed: Double) {
        guard decibels.isFinite, elapsed.isFinite, elapsed >= 0 else { return }
        peakDB = max(peakDB, min(0, decibels))
        self.elapsed = max(self.elapsed, elapsed)
    }
    public var hasAudibleInput: Bool { peakDB > -65 }
    public var quietInputHint: String? {
        elapsed >= 5 && !hasAudibleInput
            ? "Very quiet input. Try speaking closer, or check that the right microphone is selected. Silence is still saved."
            : nil
    }
}

public enum CaptureDiskPolicy {
    public static let reserveBytes: Int64 = 32 * 1_024 * 1_024
    /// Continuous capture needs already-free space, rather than an estimate
    /// that includes purgeable storage. Invalidate cached values on every poll.
    public static func availableCapacity(at folder: URL) throws -> Int64? {
        var fresh = folder
        fresh.removeAllCachedResourceValues()
        let bytes = try fresh.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        guard let bytes, bytes >= 0 else { return nil }
        return Int64(bytes)
    }
    public static func stopReason(availableBytes: Int64?) -> String? {
        guard let availableBytes, availableBytes >= 0, availableBytes < reserveBytes else { return nil }
        return "The recordings disk is almost full. Recording stopped to leave room to save the captured audio. Free some space before recording again."
    }
}
