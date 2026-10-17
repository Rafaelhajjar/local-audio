import Foundation
import Synchronization
import XCTest
@testable import LocalAudioCore

final class CaptureSupportTests: XCTestCase {
    func testConcurrentDeadlineAndWriterCallbacksCanCompleteOnlyOnce() {
        let gate = CaptureCompletionGate()
        let winners = CaptureTestCounter()
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            if gate.claim() { winners.increment() }
        }
        XCTAssertEqual(winners.value, 1)
        XCTAssertTrue(gate.isCompleted)
        XCTAssertFalse(gate.claim())
    }

    func testIndependentDeadlineCompletesWhileWriterQueueIsBlocked() {
        let gate = CaptureCompletionGate()
        let writerQueue = DispatchQueue(label: "local.audio.test.blocked-writer")
        let releaseWriter = DispatchSemaphore(value: 0)
        let deadlineFinished = DispatchSemaphore(value: 0)
        let lateWriterWins = CaptureTestCounter()
        writerQueue.async {
            releaseWriter.wait()
            if gate.claim() { lateWriterWins.increment() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
            if gate.claim() { deadlineFinished.signal() }
        }
        let result = deadlineFinished.wait(timeout: .now() + 1)
        releaseWriter.signal()
        writerQueue.sync {}
        XCTAssertEqual(result, .success)
        XCTAssertTrue(gate.isCompleted)
        XCTAssertEqual(lateWriterWins.value, 0)
    }

    func testAppendedFramesDetermineElapsedAndVerifiedSave() throws {
        let first = try CaptureProgress().appending(frames: 480, at: 120.0, sampleRate: 48_000)
        let second = try first.appending(frames: 480, at: 120.01, sampleRate: 48_000)
        XCTAssertEqual(first.frames, 480)
        XCTAssertEqual(second.frames, 960)
        XCTAssertEqual(second.elapsed, 0.02, accuracy: 0.000_001)
        XCTAssertNoThrow(try second.verify(finalFrames: 960, sampleRate: 48_000))
    }

    func testEmptyTruncatedAndWrongRateFinalFilesCannotBeAnnouncedAsSaved() throws {
        XCTAssertThrowsError(try CaptureProgress().verify(finalFrames: 0, sampleRate: 48_000))
        let progress = try CaptureProgress().appending(frames: 480, at: 1, sampleRate: 48_000)
        XCTAssertThrowsError(try progress.verify(finalFrames: 0, sampleRate: 48_000))
        XCTAssertThrowsError(try progress.verify(finalFrames: 479, sampleRate: 48_000))
        XCTAssertThrowsError(try progress.verify(finalFrames: 481, sampleRate: 48_000))
        XCTAssertThrowsError(try progress.verify(finalFrames: 480, sampleRate: 44_100))
        XCTAssertThrowsError(try progress.verify(finalFrames: 480, sampleRate: .nan))
    }

    func testInvalidBuffersDoNotMutatePreviousProgress() throws {
        let first = try CaptureProgress().appending(frames: 480, at: 10, sampleRate: 48_000)
        XCTAssertThrowsError(try first.appending(frames: 0, at: 10.01, sampleRate: 48_000))
        XCTAssertThrowsError(try first.appending(frames: -1, at: 10.01, sampleRate: 48_000))
        XCTAssertThrowsError(try first.appending(frames: 480, at: .nan, sampleRate: 48_000))
        XCTAssertThrowsError(try first.appending(frames: 480, at: .infinity, sampleRate: 48_000))
        XCTAssertThrowsError(try first.appending(frames: 480, at: 9.99, sampleRate: 48_000))
        XCTAssertThrowsError(try first.appending(frames: 480, at: 10, sampleRate: 48_000))
        XCTAssertThrowsError(try first.appending(frames: 480, at: 10.01, sampleRate: 44_100))
        XCTAssertThrowsError(try first.appending(frames: 480, at: 10.01, sampleRate: 0))
        XCTAssertEqual(first.frames, 480)
        XCTAssertEqual(first.elapsed, 0.01, accuracy: 0.000_001)
    }

    func testSilentBuffersStillCountAsRecordedAudio() throws {
        let silence = Data(repeating: 0, count: 960)
        XCTAssertEqual(PCMLevelMeter.peakDB(in: silence, encoding: .signedInteger(bits: 16, bigEndian: false)), -160)
        let progress = try CaptureProgress().appending(frames: 480, at: 1, sampleRate: 48_000)
        XCTAssertEqual(progress.frames, 480)
        XCTAssertNoThrow(try progress.verify(finalFrames: 480, sampleRate: 48_000))
    }

    func testStopBeforePermissionOrSessionSetupRemainsStoppedForThatRun() {
        let gate = CaptureStopGate()
        let cancelledStart = UUID()
        let laterDeliberateStart = UUID()
        XCTAssertFalse(gate.isStopped(cancelledStart))
        gate.stop(cancelledStart)
        gate.stop(cancelledStart)
        XCTAssertTrue(gate.isStopped(cancelledStart))
        XCTAssertFalse(gate.isStopped(laterDeliberateStart))
    }

    func testRapidStartsAtSameTimeHaveDistinctPublishedAndHiddenStagingNames() {
        let folder = URL(fileURLWithPath: "/isolated/recordings", isDirectory: true)
        let date = Date(timeIntervalSince1970: 100)
        let first = CaptureDestination.uniqueURL(in: folder, date: date)
        let second = CaptureDestination.uniqueURL(in: folder, date: date)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.pathExtension, "caf")
        XCTAssertFalse(first.lastPathComponent.hasPrefix("."))
        let stage = CaptureDestination.stagingURL(in: folder, identifier: UUID())
        XCTAssertTrue(stage.lastPathComponent.hasPrefix(".recording-"))
        XCTAssertTrue(stage.lastPathComponent.hasSuffix(".incomplete.caf"))
        XCTAssertEqual(stage.deletingLastPathComponent(), first.deletingLastPathComponent())
    }

    func testDestinationProbeCreatesFolderAndLeavesNoScratchFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-audio-capture-destination-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("recordings", isDirectory: true)
        try CaptureDestination.prepare(folder)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        let blockingFile = root.appendingPathComponent("a-file")
        let bytes = Data("preserve blocking file".utf8)
        try bytes.write(to: blockingFile)
        XCTAssertThrowsError(try CaptureDestination.prepare(blockingFile))
        XCTAssertEqual(try Data(contentsOf: blockingFile), bytes)
        XCTAssertThrowsError(try CaptureDestination.prepare(URL(string: "https://example.invalid/recordings")!))
    }

    func testLowDiskPreflightHasAnExplicitFailureAndUnknownCapacityIsNotInvented() {
        XCTAssertThrowsError(try CaptureDestination.requireDiskSpace(availableBytes: 0))
        XCTAssertThrowsError(try CaptureDestination.requireDiskSpace(availableBytes: 16 * 1_024 * 1_024 - 1))
        XCTAssertNoThrow(try CaptureDestination.requireDiskSpace(availableBytes: 16 * 1_024 * 1_024))
        XCTAssertNoThrow(try CaptureDestination.requireDiskSpace(availableBytes: nil))
    }

    func testIntegerMeterHandlesNegativeFullScaleAndBothByteOrders() {
        XCTAssertEqual(PCMLevelMeter.peakDB(in: Data([0x00, 0x80]), encoding: .signedInteger(bits: 16, bigEndian: false)), 0)
        XCTAssertEqual(PCMLevelMeter.peakDB(in: Data([0x80, 0x00]), encoding: .signedInteger(bits: 16, bigEndian: true)), 0)
        XCTAssertEqual(PCMLevelMeter.peakDB(in: Data([0x00, 0x40]), encoding: .signedInteger(bits: 16, bigEndian: false)), -6.020_599_913, accuracy: 0.000_001)
        XCTAssertEqual(PCMLevelMeter.peakDB(in: Data([0x00, 0x00, 0x80]), encoding: .signedInteger(bits: 24, bigEndian: false)), 0)
        XCTAssertEqual(PCMLevelMeter.peakDB(in: Data([0x00, 0x00, 0x00, 0x80]), encoding: .signedInteger(bits: 32, bigEndian: false)), 0)
    }

    func testMeterUsesPeakAcrossInterleavedChannelsAndIgnoresPartialTrailingSample() {
        let stereo = Data([0, 0, 0, 0x40, 0, 0x80, 0, 0])
        XCTAssertEqual(PCMLevelMeter.peakDB(in: stereo, encoding: .signedInteger(bits: 16, bigEndian: false)), 0)
        XCTAssertEqual(PCMLevelMeter.peakDB(in: Data([0xff]), encoding: .signedInteger(bits: 16, bigEndian: false)), -160)
        XCTAssertEqual(PCMLevelMeter.peakDB(in: Data(), encoding: .signedInteger(bits: 16, bigEndian: false)), -160)
    }

    func testFloatingMeterClampsClippingAndRejectsNonfiniteLevels() {
        func littleEndian(_ values: [Float]) -> Data {
            var bytes = Data()
            for value in values {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
            }
            return bytes
        }
        XCTAssertEqual(PCMLevelMeter.peakDB(in: littleEndian([0, -0.5]), encoding: .floatingPoint(bits: 32, bigEndian: false)), -6.020_599_913, accuracy: 0.000_001)
        XCTAssertEqual(PCMLevelMeter.peakDB(in: littleEndian([2]), encoding: .floatingPoint(bits: 32, bigEndian: false)), 0)
        XCTAssertEqual(PCMLevelMeter.peakDB(in: littleEndian([.nan, .infinity]), encoding: .floatingPoint(bits: 32, bigEndian: false)), -160)
    }
}

private final class CaptureTestCounter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}
