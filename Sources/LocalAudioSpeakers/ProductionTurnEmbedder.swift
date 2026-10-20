import Foundation
import LocalAudioCore

enum ProductionTurnEmbedder {
    /// Model scores weight evidence within one human-labelable turn; they never
    /// supply identities or enroll additional independent examples.
    static func extract(_ original: [VoiceTurn], source: URL, using embedder: ClipEmbedder) throws -> [VoiceTurn] {
        let geometry = original.map { TurnEmbeddingPolicy.Geometry(start: $0.start, end: $0.end, speakerID: $0.speakerID) }
        return try original.enumerated().map { index, originalTurn in
            try Task.checkCancellation()
            var evidence: [TurnEmbeddingPolicy.Evidence] = []
            for window in TurnEmbeddingPolicy.windows(for: geometry[index], among: geometry) {
                try Task.checkCancellation()
                let span = SpeakerSampleSpan(start: window.start, end: window.end)
                guard let vector = try embedder.embedForExperiment(source: source, span: span, paddingMode: .repeatOriginalMask) else { continue }
                let quality = try embedder.diagnostics(source: source, span: span)
                evidence.append(.init(window: window, vector: vector, dominantSoloSeconds: quality.dominantSoloSeconds))
            }
            return replacingEvidence(in: originalTurn, with: TurnEmbeddingPolicy.aggregate(evidence))
        }
    }

    static func replacingEvidence(in original: VoiceTurn, with aggregate: TurnEmbeddingPolicy.Aggregate?) -> VoiceTurn {
        var turn = original
        turn.confirmedPersonID = nil
        turn.embedding = aggregate?.vector
        turn.sampleStart = aggregate?.representative.start
        turn.sampleEnd = aggregate?.representative.end
        turn.embeddingSpans = aggregate?.contributing.map { VoiceSampleSpan(start: $0.start, end: $0.end) }
        return turn
    }
}
