import Foundation

/// Experimental review suggestions, never identity decisions or enrollment.
public enum VoiceMatcher {
    public static let minimumSimilarity = 0.92
    public static let minimumMargin = 0.12

    public static func suggestion(for turn: VoiceTurn, in analysis: VoiceAnalysis,
                                  profiles: [VoiceProfile]) -> VoiceCandidate? {
        guard analysis.version == 1, !analysis.recordingID.isEmpty, !analysis.audioHash.isEmpty,
              !analysis.modelID.isEmpty, turn.confirmedPersonID == nil,
              turn.start.isFinite, turn.end.isFinite, turn.start >= 0, turn.end > turn.start,
              let sampleStart = turn.sampleStart, let sampleEnd = turn.sampleEnd,
              sampleStart.isFinite, sampleEnd.isFinite, sampleStart >= turn.start, sampleEnd <= turn.end,
              sampleEnd - sampleStart >= 2, sampleEnd - sampleStart <= 5.000_001,
              let query = normalized(turn.embedding) else { return nil }
        struct Score { let profile: VoiceProfile; let value: Double; let count: Int }
        var scores: [Score] = []
        for profile in profiles {
            // Duplicate copies/examples of one source cannot multiply its vote.
            var byHash: [String: Double] = [:]
            for example in profile.examples {
                guard example.modelID == analysis.modelID,
                      example.recordingID != analysis.recordingID,
                      example.audioHash != analysis.audioHash,
                      !example.recordingID.isEmpty, !example.audioHash.isEmpty,
                      example.start.isFinite, example.end.isFinite,
                      example.end - example.start >= 2, example.end - example.start <= 5.000_001,
                      let vector = normalized(example.embedding) else { continue }
                let cosine = min(1, max(-1, zip(query, vector).reduce(0) { $0 + Double($1.0) * Double($1.1) }))
                byHash[example.audioHash] = max(byHash[example.audioHash] ?? -1, cosine)
            }
            let best = byHash.values.sorted(by: >).prefix(2)
            guard !best.isEmpty else { continue }
            scores.append(Score(profile: profile, value: best.reduce(0, +) / Double(best.count), count: byHash.count))
        }
        scores.sort { $0.value == $1.value ? $0.profile.id < $1.profile.id : $0.value > $1.value }
        guard let best = scores.first else { return nil }
        let margin = best.value - (scores.dropFirst().first?.value ?? 0)
        guard best.value >= minimumSimilarity, margin >= minimumMargin else { return nil }
        return VoiceCandidate(personID: best.profile.id, name: best.profile.name,
                              similarity: best.value, margin: margin, exampleCount: best.count)
    }

    /// Normalize at the boundary; zero, malformed and nonfinite vectors abstain.
    static func normalized(_ vector: [Float]?) -> [Float]? {
        guard let vector, vector.count == 256, vector.allSatisfy(\.isFinite) else { return nil }
        let squaredNorm = vector.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard squaredNorm.isFinite, squaredNorm > 1e-16 else { return nil }
        let norm = sqrt(squaredNorm)
        let result = vector.map { Float(Double($0) / norm) }
        return result.allSatisfy(\.isFinite) ? result : nil
    }
}
