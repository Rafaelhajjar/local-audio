import Foundation
import XCTest
import LocalAudioCore
@testable import LocalAudioSpeakers

final class TurnEmbeddingPolicyTests: XCTestCase {
    private func geometry(_ start: Double, _ end: Double, _ speaker: String = "S1") -> TurnEmbeddingPolicy.Geometry {
        .init(start: start, end: end, speakerID: speaker)
    }
    private func vector(_ axis: Int, scale: Float = 1) -> [Float] {
        var values = [Float](repeating: 0, count: 256); values[axis] = scale; return values
    }
    private func evidence(_ kind: String, axis: Int, weight: Double, start: Double = 0.15) -> TurnEmbeddingPolicy.Evidence {
        .init(window: .init(kind: kind, start: start, end: start + 5), vector: vector(axis, scale: 3), dominantSoloSeconds: weight)
    }

    func testExactEightSecondPolicyAndBoundaryMargins() {
        let turn = geometry(100, 108)
        let windows = TurnEmbeddingPolicy.windows(for: turn, among: [turn])
        XCTAssertEqual(windows.map(\.kind), ["center", "start5", "end5"])
        XCTAssertEqual(windows[0].start, 101.5, accuracy: 1e-9)
        XCTAssertEqual(windows[0].end, 106.5, accuracy: 1e-9)
        XCTAssertEqual(windows[1].start, 100.15, accuracy: 1e-9)
        XCTAssertEqual(windows[1].end, 105.15, accuracy: 1e-9)
        XCTAssertEqual(windows[2].start, 102.85, accuracy: 1e-9)
        XCTAssertEqual(windows[2].end, 107.85, accuracy: 1e-9)
        let shorter = geometry(100, 107.999)
        XCTAssertEqual(TurnEmbeddingPolicy.windows(for: shorter, among: [shorter]).count, 1)
    }

    func testShortAndInvalidTurnsCannotSupplyExamples() {
        for turn in [geometry(0, 2.2), geometry(-1, 5), geometry(5, 4), geometry(0, .infinity)] {
            XCTAssertTrue(TurnEmbeddingPolicy.windows(for: turn, among: [turn]).isEmpty)
        }
        let turn = geometry(10, 13)
        let windows = TurnEmbeddingPolicy.windows(for: turn, among: [turn])
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].start, 10.15, accuracy: 1e-9)
        XCTAssertEqual(windows[0].end, 12.85, accuracy: 1e-9)
        let minimum = geometry(0, 2.3)
        let minimumWindows = TurnEmbeddingPolicy.windows(for: minimum, among: [minimum])
        XCTAssertEqual(minimumWindows.count, 1)
        XCTAssertEqual(minimumWindows[0].end - minimumWindows[0].start, 2, accuracy: 1e-9)
    }

    func testOverlapRejectsBoundaryWindowsAndRecentersOnCleanRegion() {
        let turn = geometry(0, 12), other = geometry(0, 5, "S2")
        let windows = TurnEmbeddingPolicy.windows(for: turn, among: [turn, other])
        XCTAssertFalse(windows.contains { $0.kind == "start5" })
        XCTAssertTrue(windows.contains { $0.kind == "end5" })
        XCTAssertTrue(windows.allSatisfy { $0.start >= 5.15 && $0.end <= 11.85 })
        let covering = geometry(0, 12, "S2")
        XCTAssertTrue(TurnEmbeddingPolicy.windows(for: turn, among: [turn, covering]).isEmpty)
        let same = geometry(0, 12, "S1")
        XCTAssertEqual(TurnEmbeddingPolicy.windows(for: turn, among: [turn, same]).count, 3)
    }

    func testRepeatedGeometryNeverCountsTwice() {
        let turn = geometry(0, 12), other = geometry(5.3, 12, "S2")
        let windows = TurnEmbeddingPolicy.windows(for: turn, among: [turn, other])
        XCTAssertEqual(windows.count, 1, "Center and start5 coincide after overlap subtraction")
        XCTAssertEqual(windows[0].kind, "center")
    }

    func testDominantSoloWeightedNormalizedMeanMatchesReferenceFormula() throws {
        let a = evidence("center", axis: 0, weight: 1)
        let b = evidence("start5", axis: 1, weight: 3, start: 5.15)
        let result = try XCTUnwrap(TurnEmbeddingPolicy.aggregate([a, b]))
        XCTAssertEqual(Double(result.vector[0]), 1 / sqrt(10), accuracy: 1e-7)
        XCTAssertEqual(Double(result.vector[1]), 3 / sqrt(10), accuracy: 1e-7)
        XCTAssertEqual(result.contributing, [a.window, b.window])
        XCTAssertEqual(result.representative, b.window)
        let tied = try XCTUnwrap(TurnEmbeddingPolicy.aggregate([a, evidence("end5", axis: 1, weight: 1)]))
        XCTAssertEqual(tied.representative, a.window)
    }

    func testNoZeroQualityFallbackAndInvalidEvidenceNeverContributes() throws {
        XCTAssertNil(TurnEmbeddingPolicy.aggregate([evidence("center", axis: 0, weight: 0)]))
        XCTAssertNil(TurnEmbeddingPolicy.aggregate([evidence("center", axis: 0, weight: 1e-13)]))
        let valid = evidence("center", axis: 0, weight: 2)
        let bad = TurnEmbeddingPolicy.Evidence(window: valid.window, vector: [.nan], dominantSoloSeconds: 4)
        let result = try XCTUnwrap(TurnEmbeddingPolicy.aggregate([valid, bad, evidence("end5", axis: 1, weight: .nan)]))
        XCTAssertEqual(result.contributing, [valid.window])
        XCTAssertEqual(result.vector, vector(0))
        let opposite = TurnEmbeddingPolicy.Evidence(window: valid.window, vector: vector(0, scale: -1), dominantSoloSeconds: 2)
        XCTAssertNil(TurnEmbeddingPolicy.aggregate([valid, opposite]), "Cancelling vectors cannot become an arbitrary name")
        for vector in [[Float](repeating: 1, count: 255), [Float](repeating: 0, count: 256),
                       [Float](repeating: .infinity, count: 256), self.vector(0, scale: 1e-9)] {
            let invalid = TurnEmbeddingPolicy.Evidence(window: valid.window, vector: vector, dominantSoloSeconds: 3)
            XCTAssertNil(TurnEmbeddingPolicy.aggregate([invalid]))
        }
    }

    func testRefreshEvidencePreservesFullGeometryAndAlwaysStripsIdentity() throws {
        let original = VoiceTurn(id: "saved-turn", start: 10, end: 30, speakerID: "S7",
            embedding: vector(0), sampleStart: 12, sampleEnd: 17, confirmedPersonID: "never-emit")
        let candidate = evidence("center", axis: 1, weight: 3, start: 15)
        let result = ProductionTurnEmbedder.replacingEvidence(in: original, with: TurnEmbeddingPolicy.aggregate([candidate]))
        XCTAssertEqual(result.id, original.id)
        XCTAssertEqual(result.start, original.start)
        XCTAssertEqual(result.end, original.end)
        XCTAssertEqual(result.speakerID, original.speakerID)
        XCTAssertNil(result.confirmedPersonID)
        XCTAssertEqual(result.embeddingSpans, [VoiceSampleSpan(start: 15, end: 20)])
        let failed = ProductionTurnEmbedder.replacingEvidence(in: original, with: nil)
        XCTAssertNil(failed.embedding); XCTAssertNil(failed.embeddingSpans)
        XCTAssertNil(failed.sampleStart); XCTAssertNil(failed.sampleEnd)
        XCTAssertNil(failed.confirmedPersonID)
    }
}
