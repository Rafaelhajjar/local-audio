import Foundation

/// Heuristic activity estimates for batch evaluation, never identity confidence
/// or a calibrated SNR/quality decision. The grid follows the frozen SDK.
struct ClipSegmentationDiagnostics: Encodable {
    static let recipeID = "powerset7-soft-sdkgrid-v1"
    let validDurationSeconds: Double
    /// Nil means exact digital silence; avoids writing non-JSON -infinity.
    let rmsDbfs: Double?
    let clippedFraction: Double
    let speechSeconds: Double
    let singleSpeakerSeconds: Double
    let overlapSeconds: Double
    let dominantSoloSeconds: Double
    let speechOccupancy: Double
    let singleSpeakerOccupancy: Double
    let overlapOccupancy: Double
    let dominantSoloOccupancy: Double
    let overlapFractionOfSpeech: Double?
    let dominantSoloFractionOfSpeech: Double?
    let hardSpeechSeconds: Double
    let hardSingleSpeakerSeconds: Double
    let hardOverlapSeconds: Double
    let hardDominantSoloSeconds: Double

    /// Uses actual resampled PCM, before zero-tail padding. Every logit row must
    /// have seven classes: none, A, B, C, A+B, A+C, B+C.
    static func calculate(samples: [Float], logProbabilities: [[Double]]) throws -> Self {
        let validCount = min(samples.count, 160_000)
        guard validCount > 0, samples.prefix(validCount).allSatisfy({ $0.isFinite }),
              logProbabilities.count == 589 else {
            throw DiagnosticError("Diagnostics require finite PCM and exactly 589 seven-class frames.")
        }
        let duration = Double(validCount) / 16_000
        var energy = 0.0
        var clipped = 0
        for value in samples.prefix(validCount) {
            energy += Double(value) * Double(value)
            if abs(value) >= 0.99 { clipped += 1 }
        }
        let meanEnergy = energy / Double(validCount)
        let rms: Double? = meanEnergy > 0 ? 10 * log10(meanEnergy) : nil
        let step = 10.0 / 589.0
        var speech = 0.0, solo = 0.0, overlap = 0.0
        var singleton = [Double](repeating: 0, count: 3)
        var hardSpeech = 0.0, hardSolo = 0.0, hardOverlap = 0.0
        var hardSingleton = [Double](repeating: 0, count: 3)
        for (index, row) in logProbabilities.enumerated() {
            // -infinity is a legitimate zero-probability class; NaN, +infinity
            // and all-negative-infinity rows cannot define a distribution.
            guard row.count == 7, row.allSatisfy({ !$0.isNaN && $0 != .infinity }),
                  let maximum = row.max(), maximum.isFinite else {
                throw DiagnosticError("Segmentation diagnostics encountered invalid seven-class logits.")
            }
            let weight = max(0, min(duration, Double(index + 1) * step) - Double(index) * step)
            guard weight > 0 else { continue } // Never score padded-only frames.
            let exponentials = row.map { exp($0 - maximum) }
            let sum = exponentials.reduce(0, +)
            let probabilities = exponentials.map { $0 / sum }
            let soloProbability = probabilities[1] + probabilities[2] + probabilities[3]
            let overlapProbability = probabilities[4] + probabilities[5] + probabilities[6]
            speech += weight * (1 - probabilities[0])
            solo += weight * soloProbability
            overlap += weight * overlapProbability
            for speaker in 0..<3 { singleton[speaker] += weight * probabilities[speaker + 1] }
            // Lowest class index wins ties, matching the SDK's strict > loop.
            let winner = row.firstIndex(of: maximum)!
            if winner != 0 { hardSpeech += weight }
            if (1...3).contains(winner) {
                hardSolo += weight
                hardSingleton[winner - 1] += weight
            } else if winner >= 4 { hardOverlap += weight }
        }
        let dominant = singleton.max() ?? 0
        func fraction(_ numerator: Double, _ denominator: Double) -> Double? {
            guard denominator > 1e-12 else { return nil }
            return min(1, max(0, numerator / denominator))
        }
        return Self(validDurationSeconds: duration, rmsDbfs: rms,
            clippedFraction: Double(clipped) / Double(validCount),
            speechSeconds: speech, singleSpeakerSeconds: solo,
            overlapSeconds: overlap, dominantSoloSeconds: dominant,
            speechOccupancy: fraction(speech, duration)!,
            singleSpeakerOccupancy: fraction(solo, duration)!,
            overlapOccupancy: fraction(overlap, duration)!,
            dominantSoloOccupancy: fraction(dominant, duration)!,
            overlapFractionOfSpeech: fraction(overlap, speech),
            dominantSoloFractionOfSpeech: fraction(dominant, speech),
            hardSpeechSeconds: hardSpeech, hardSingleSpeakerSeconds: hardSolo,
            hardOverlapSeconds: hardOverlap, hardDominantSoloSeconds: hardSingleton.max() ?? 0)
    }

    private struct DiagnosticError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
