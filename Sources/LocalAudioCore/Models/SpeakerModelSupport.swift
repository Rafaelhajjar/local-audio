import Foundation

public enum SpeakerModelCompatibility {
    /// Voice examples are keyed to the exact embedding pack. Verify all runtime
    /// asset bytes even for an externally selected folder; notices may be absent
    /// from older local caches, which remain read-only.
    public static func validate(in folder: URL) throws {
        let manifest = try ModelManifest.bundled(pack: .speakers)
        guard folder.isFileURL else { throw ModelSetupError.message("Choose a local speaker-model folder.") }
        for file in manifest.files where !ModelPack.speakers.attributionFiles.contains(file.path) {
            try Task.checkCancellation()
            do { try ModelFileIntegrity.verify(folder.appendingPathComponent(file.path), expected: file) }
            catch is CancellationError { throw CancellationError() }
            catch {
                throw ModelSetupError.message("The selected speaker models are incomplete or differ from the supported Community-1 pack. "
                    + "Install or repair Speaker Models in Settings. Your folder was not changed. \(error.localizedDescription)")
            }
        }
    }

    public static func pldaPsi(from data: Data) throws -> [Double] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any], let tensors = root["tensors"] as? [String: Any],
              let psi = tensors["psi"] as? [String: Any], let encoded = psi["data_base64"] as? String,
              let bytes = Data(base64Encoded: encoded), bytes.count == 128 * 4 else {
            throw ModelSetupError.message("The speaker PLDA parameters must contain 128 float32 values. Repair Speaker Models in Settings.")
        }
        let raw = [UInt8](bytes)
        return try stride(from: 0, to: raw.count, by: 4).map { offset in
            let bits = UInt32(raw[offset]) | UInt32(raw[offset + 1]) << 8
                | UInt32(raw[offset + 2]) << 16 | UInt32(raw[offset + 3]) << 24
            let value = Float(bitPattern: bits)
            guard value.isFinite, value >= 0 else { throw ModelSetupError.message("Invalid speaker PLDA parameters. Repair Speaker Models in Settings.") }
            return Double(value)
        }
    }
}

public struct SpeakerSampleSpan: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

public enum SpeakerClipPolicy {
    /// Conservative representative selection, not a calibrated quality score.
    /// A turn remains labelable when no sufficiently long clean excerpt exists.
    public static func representativeSpan(for turn: VoiceTurn, among turns: [VoiceTurn]) -> SpeakerSampleSpan? {
        guard turn.start.isFinite, turn.end.isFinite, turn.start >= 0, turn.end > turn.start else { return nil }
        let margin = 0.15
        var clean = [SpeakerSampleSpan(start: turn.start + margin, end: turn.end - margin)]
        for other in turns where other.speakerID != turn.speakerID && other.start.isFinite && other.end.isFinite {
            let excluded = SpeakerSampleSpan(start: other.start - margin, end: other.end + margin)
            clean = clean.flatMap { span -> [SpeakerSampleSpan] in
                guard excluded.start < span.end, excluded.end > span.start else { return [span] }
                var pieces: [SpeakerSampleSpan] = []
                if excluded.start > span.start { pieces.append(.init(start: span.start, end: min(span.end, excluded.start))) }
                if excluded.end < span.end { pieces.append(.init(start: max(span.start, excluded.end), end: span.end)) }
                return pieces
            }
        }
        guard let best = clean.filter({ $0.end - $0.start >= 2 }).max(by: { $0.end - $0.start < $1.end - $1.start }) else { return nil }
        let duration = min(5, best.end - best.start)
        let middle = (best.start + best.end) / 2
        return .init(start: middle - duration / 2, end: middle + duration / 2)
    }

    public static func hasUsableSignal(_ samples: [Float]) -> Bool {
        guard samples.count >= 32_000, samples.allSatisfy(\.isFinite) else { return false }
        let meanEnergy = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        let clipped = samples.reduce(0) { $0 + (abs($1) >= 0.99 ? 1 : 0) }
        return meanEnergy >= 1e-7 && Double(clipped) / Double(samples.count) < 0.02
    }

    public static func normalizedEmbedding(_ values: [Float]) -> [Float]? {
        guard values.count == 256, values.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 1e-8 else { return nil }
        return values.map { Float(Double($0) / norm) }
    }
}
