import Foundation
import XCTest
@testable import LocalAudioSpeakers

final class ClipDiagnosticsTests: XCTestCase {
    private let samples = [Float](repeating: 0.1, count: 32_000)
    private func row(_ winner: Int) -> [Double] {
        var values = [Double](repeating: -.infinity, count: 7); values[winner] = 0; return values
    }
    func testPowersetSilenceSingletonOverlapAndHardParity() throws {
        let silence = try ClipSegmentationDiagnostics.calculate(samples: samples, logProbabilities: .init(repeating: row(0), count: 589))
        XCTAssertEqual(silence.speechSeconds, 0)
        XCTAssertNil(silence.dominantSoloFractionOfSpeech)
        let single = try ClipSegmentationDiagnostics.calculate(samples: samples, logProbabilities: .init(repeating: row(1), count: 589))
        XCTAssertEqual(single.speechSeconds, 2, accuracy: 1e-9)
        XCTAssertEqual(single.dominantSoloSeconds, 2, accuracy: 1e-9)
        XCTAssertEqual(single.hardSpeechSeconds, 2, accuracy: 1e-9)
        let pair = try ClipSegmentationDiagnostics.calculate(samples: samples, logProbabilities: .init(repeating: row(4), count: 589))
        XCTAssertEqual(pair.overlapSeconds, 2, accuracy: 1e-9)
        XCTAssertEqual(pair.singleSpeakerSeconds, 0)
        XCTAssertEqual(pair.hardOverlapSeconds, 2, accuracy: 1e-9)
    }
    func testFractionalLastFrameAndPaddedTailAreHandledSeparately() throws {
        var rows = [[Double]](repeating: row(0), count: 589)
        rows[117] = row(1)
        for index in 118..<589 { rows[index] = row(4) }
        let result = try ClipSegmentationDiagnostics.calculate(samples: samples, logProbabilities: rows)
        XCTAssertEqual(result.speechSeconds, 2 - 117 * (10.0 / 589), accuracy: 1e-9)
        XCTAssertEqual(result.overlapSeconds, 0)
        XCTAssertEqual(result.validDurationSeconds, 2)
    }
    func testStableSoftmaxAndSequentialSpeakerPurity() throws {
        let p = [0.1, 0.2, 0.1, 0.1, 0.25, 0.15, 0.1]
        let rows = [[Double]](repeating: p.map { log($0) + 10_000 }, count: 589)
        let result = try ClipSegmentationDiagnostics.calculate(samples: samples, logProbabilities: rows)
        XCTAssertEqual(result.speechSeconds, 1.8, accuracy: 1e-9)
        XCTAssertEqual(result.singleSpeakerSeconds, 0.8, accuracy: 1e-9)
        XCTAssertEqual(result.overlapSeconds, 1, accuracy: 1e-9)
        XCTAssertEqual(result.dominantSoloSeconds, 0.4, accuracy: 1e-9)
        var sequential = [[Double]](repeating: row(2), count: 589)
        for index in 0..<59 { sequential[index] = row(1) }
        let split = try ClipSegmentationDiagnostics.calculate(samples: samples, logProbabilities: sequential)
        XCTAssertEqual(split.singleSpeakerSeconds, 2, accuracy: 1e-9)
        XCTAssertLessThan(split.dominantSoloFractionOfSpeech!, 0.51)
    }
    func testInvalidLogitsFailInsteadOfInventingQualityAndSilenceEncodesSafely() throws {
        for badRow in [[Double](repeating: -.infinity, count: 7), [0, .nan, 0, 0, 0, 0, 0], [0, .infinity, 0, 0, 0, 0, 0], [0, 0]] {
            XCTAssertThrowsError(try ClipSegmentationDiagnostics.calculate(samples: samples, logProbabilities: .init(repeating: badRow, count: 589)))
        }
        let silence = try ClipSegmentationDiagnostics.calculate(samples: .init(repeating: 0, count: 32_000), logProbabilities: .init(repeating: row(0), count: 589))
        XCTAssertNil(silence.rmsDbfs)
        XCTAssertNoThrow(try JSONEncoder().encode(silence))
    }
}
