import Foundation

public struct MicrophoneChoice: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var isBuiltIn: Bool
    public init(id: String, name: String, isBuiltIn: Bool = false) {
        self.id = id; self.name = name; self.isBuiltIn = isBuiltIn
    }
}

public struct MicrophonePolicy: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case manual, approved, macAlways }
    public var mode: Mode = .manual
    public var allowMacMicrophone = true
    public var approved: [MicrophoneChoice] = []
    public init() {}

    /// Always resolve to a concrete input. Never let AVFoundation silently fall
    /// back to the system microphone when an approved device is absent.
    public func resolve(devices: [MicrophoneChoice], selectedID: String?, defaultID: String?) -> MicrophoneChoice? {
        let eligible = devices.filter { allowMacMicrophone || !$0.isBuiltIn }
        switch mode {
        case .manual: return eligible.first { $0.id == (selectedID ?? defaultID) }
        case .approved:
            return approved.compactMap { choice in eligible.first { $0.id == choice.id } }.first
        case .macAlways: return allowMacMicrophone ? eligible.first { $0.isBuiltIn } : nil
        }
    }
}

public struct AudioRetention: Codable, Equatable, Sendable {
    public var days: Int
    public var enabledAt: Date
    public init(days: Int = 7, enabledAt: Date = Date()) { self.days = days; self.enabledAt = enabledAt }
    public func isDue(_ recording: AudioRecording, now: Date = Date()) -> Bool {
        guard [7, 30].contains(days), recording.hasAudio, recording.metadata.vaultedAt == nil,
              recording.metadata.audioRemovedAt == nil, let managedAt = recording.metadata.managedAt else { return false }
        let baseline = max(enabledAt, managedAt)
        return now.timeIntervalSince(baseline) >= Double(days) * 86_400
    }
}

/// Failed inputs stay blocked until they disconnect, or the user explicitly
/// starts a new monitoring session. This prevents permission/disk failure loops.
public struct MicrophoneAutomation: Sendable {
    public private(set) var blockedIDs: Set<String> = []
    public init() {}
    public mutating func failed(_ id: String) { blockedIDs.insert(id) }
    public mutating func connected(_ devices: [MicrophoneChoice]) {
        blockedIDs.formIntersection(Set(devices.map(\.id)))
    }
    public func available(_ devices: [MicrophoneChoice]) -> [MicrophoneChoice] {
        devices.filter { !blockedIDs.contains($0.id) }
    }
}
