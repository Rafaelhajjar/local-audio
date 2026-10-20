import Foundation

/// Experimental review suggestions, never identity decisions or enrollment.
public enum VoiceMatcher {
    public static let minimumSimilarity = 0.92
    public static let minimumMargin = 0.12
    /// Development review heuristics for the new recipe, not calibrated accuracy.
    public static let experimentalMinimumSimilarity = 0.60
    public static let experimentalMinimumMargin = 0.15

    public static func suggestion(for turn: VoiceTurn, in analysis: VoiceAnalysis,
                                  profiles: [VoiceProfile]) -> VoiceCandidate? {
        guard (analysis.version == 1 || analysis.version == 2), VoiceEmbeddingRecipe.isSupported(analysis.recipeID),
              (analysis.version != 1 || analysis.recipeID == VoiceEmbeddingRecipe.legacy),
              !analysis.recordingID.isEmpty, !analysis.audioHash.isEmpty,
              !analysis.modelID.isEmpty, turn.confirmedPersonID == nil,
              turn.start.isFinite, turn.end.isFinite, turn.start >= 0, turn.end > turn.start,
              let sampleStart = turn.sampleStart, let sampleEnd = turn.sampleEnd,
              sampleStart.isFinite, sampleEnd.isFinite, sampleStart >= turn.start, sampleEnd <= turn.end,
              sampleEnd - sampleStart >= 2, sampleEnd - sampleStart <= 5.000_001,
              let query = normalized(turn.embedding) else { return nil }
        if analysis.recipeID == VoiceEmbeddingRecipe.current {
            guard validSpans(turn.embeddingSpans, previewStart: sampleStart, previewEnd: sampleEnd,
                             within: VoiceSampleSpan(start: turn.start, end: turn.end)) else { return nil }
        }
        struct Score { let profile: VoiceProfile; let value: Double; let count: Int }
        var scores: [Score] = []
        for profile in profiles {
            // Duplicate copies/examples of one source cannot multiply its vote.
            var byHash: [String: [[Float]]] = [:]
            var representedWindows = Set<String>()
            for example in profile.examples {
                guard example.isAvailableForMatching, example.modelID == analysis.modelID,
                      example.recipeID == analysis.recipeID,
                      example.recordingID != analysis.recordingID,
                      example.audioHash != analysis.audioHash,
                      !example.recordingID.isEmpty, !example.audioHash.isEmpty,
                      example.start.isFinite, example.end.isFinite,
                      example.end - example.start >= 2, example.end - example.start <= 5.000_001,
                      let vector = normalized(example.embedding) else { continue }
                if example.recipeID == VoiceEmbeddingRecipe.current,
                   !validSpans(example.embeddingSpans, previewStart: example.start, previewEnd: example.end) { continue }
                if example.recipeID == VoiceEmbeddingRecipe.current {
                    let spans = example.embeddingSpans!.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
                    let key = example.audioHash + spans.map { "|\($0.start):\($0.end)" }.joined()
                    guard representedWindows.insert(key).inserted else { continue }
                }
                byHash[example.audioHash, default: []].append(vector)
            }
            guard !byHash.isEmpty else { continue }
            let value: Double
            if analysis.recipeID == VoiceEmbeddingRecipe.current {
                // One normalized mean per complete source file, then an equally
                // weighted normalized mean of those source prototypes. Repeated
                // utterances from one file cannot outweigh another whole file.
                var prototypes: [[Float]] = []
                var invalid = false
                for vectors in byHash.values {
                    guard let center = mean(vectors) else { invalid = true; break }
                    prototypes.append(center)
                }
                guard !invalid, let center = mean(prototypes) else { continue }
                value = cosine(query, center)
            } else {
                let best = byHash.values.map { vectors in vectors.map { cosine(query, $0) }.max()! }.sorted(by: >).prefix(2)
                value = best.reduce(0, +) / Double(best.count)
            }
            scores.append(Score(profile: profile, value: value, count: byHash.count))
        }
        scores.sort { $0.value == $1.value ? $0.profile.id < $1.profile.id : $0.value > $1.value }
        guard let best = scores.first else { return nil }
        let margin = best.value - (scores.dropFirst().first?.value ?? 0)
        let similarityGate = analysis.recipeID == VoiceEmbeddingRecipe.current ? experimentalMinimumSimilarity : minimumSimilarity
        let marginGate = analysis.recipeID == VoiceEmbeddingRecipe.current ? experimentalMinimumMargin : minimumMargin
        guard best.value >= similarityGate, margin >= marginGate else { return nil }
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

    static func validSpans(_ spans: [VoiceSampleSpan]?, previewStart: Double, previewEnd: Double,
                           within turn: VoiceSampleSpan? = nil) -> Bool {
        guard let spans, !spans.isEmpty, spans.count <= 3,
              spans.contains(VoiceSampleSpan(start: previewStart, end: previewEnd)) else { return false }
        var seen = Set<String>()
        return spans.allSatisfy { span in
            span.start.isFinite && span.end.isFinite && span.start >= 0 &&
            span.end - span.start >= 2 && span.end - span.start <= 5.000_001 &&
            (turn.map { span.start >= $0.start && span.end <= $0.end } ?? true) &&
            seen.insert("\(span.start)|\(span.end)").inserted
        }
    }

    private static func mean(_ vectors: [[Float]]) -> [Float]? {
        guard !vectors.isEmpty else { return nil }
        return normalized((0..<256).map { index in
            Float(vectors.reduce(0.0) { $0 + Double($1[index]) } / Double(vectors.count))
        })
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        min(1, max(-1, zip(a, b).reduce(0) { $0 + Double($1.0) * Double($1.1) }))
    }
}
