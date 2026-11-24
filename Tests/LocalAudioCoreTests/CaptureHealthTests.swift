import Foundation
import XCTest
@testable import LocalAudioCore

final class CaptureHealthTests: XCTestCase {
    func testQuietInputHintWaitsAndNeverRejectsSilence() throws {
        var signal = CaptureSignal()
        signal.observe(decibels: -160, elapsed: 4.9)
        XCTAssertNil(signal.quietInputHint)
        signal.observe(decibels: -160, elapsed: 5)
        XCTAssertNotNil(signal.quietInputHint)
        XCTAssertFalse(signal.hasAudibleInput)
        var frames = CaptureProgress()
        frames = try frames.appending(frames: 240_000, at: 37, sampleRate: 48_000)
        XCTAssertNoThrow(try frames.verify(finalFrames: 240_000, sampleRate: 48_000))
    }

    func testInputEvidencePersistsAfterQuietTailAndIgnoresInvalidValues() {
        var signal = CaptureSignal()
        signal.observe(decibels: -32, elapsed: 1)
        signal.observe(decibels: -160, elapsed: 10)
        signal.observe(decibels: .nan, elapsed: 11)
        signal.observe(decibels: 0, elapsed: .infinity)
        signal.observe(decibels: 0, elapsed: -1)
        XCTAssertTrue(signal.hasAudibleInput)
        XCTAssertNil(signal.quietInputHint)
        XCTAssertEqual(signal.peakDB, -32)
        XCTAssertEqual(signal.elapsed, 10)
    }

    func testDiskReserveStopsOnlyForKnownLowCapacity() {
        XCTAssertNotNil(CaptureDiskPolicy.stopReason(availableBytes: 0))
        XCTAssertNotNil(CaptureDiskPolicy.stopReason(availableBytes: CaptureDiskPolicy.reserveBytes - 1))
        XCTAssertNil(CaptureDiskPolicy.stopReason(availableBytes: CaptureDiskPolicy.reserveBytes))
        XCTAssertNil(CaptureDiskPolicy.stopReason(availableBytes: nil))
        XCTAssertNil(CaptureDiskPolicy.stopReason(availableBytes: -1))
    }

    func testRecoveryDiscoveryPreservesOriginalBytesAndExcludesLinksAndOrdinaryAudio() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let abandoned = CaptureDestination.stagingURL(in: folder, identifier: UUID())
        let bytes = Data("incomplete CAF bytes must remain untouched".utf8)
        try bytes.write(to: abandoned)
        try bytes.write(to: folder.appendingPathComponent("ordinary.caf"))
        let link = CaptureDestination.stagingURL(in: folder, identifier: UUID())
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: abandoned)
        let library = RecordingLibrary(folder: folder)
        let found = try await library.interruptedRecordingURLs()
        XCTAssertEqual(found.map { $0.resolvingSymlinksInPath() }, [abandoned.resolvingSymlinksInPath()])
        XCTAssertEqual(try Data(contentsOf: abandoned), bytes)
        let missing = RecordingLibrary(folder: folder.appendingPathComponent("missing"))
        let missingResults = try await missing.interruptedRecordingURLs()
        XCTAssertTrue(missingResults.isEmpty)
    }
}
