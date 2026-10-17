import AVFoundation
import CoreMedia
import Foundation
import XCTest
import LocalAudioCore
@testable import LocalAudioApp

@MainActor
final class PCMRecordingWriterTests: XCTestCase {
    private struct Fixture {
        let writer: PCMRecordingWriter
        let gate: CaptureCompletionGate
        let staging: URL
        let published: URL
    }

    private enum FixtureError: Error {
        case coreMedia(String, OSStatus)
        case noBuffer
        case unexpectedOutcome(String)
    }

    private func fixture() throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAudio-native-CAF-" + UUID().uuidString)
        try CaptureDestination.prepare(folder)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        let staging = CaptureDestination.stagingURL(in: folder, identifier: id)
        let published = CaptureDestination.uniqueURL(in: folder, identifier: id)
        let gate = CaptureCompletionGate()
        return Fixture(writer: PCMRecordingWriter(stagingURL: staging, publishedURL: published,
            completionGate: gate, callbackQueue: .main), gate: gate, staging: staging, published: published)
    }

    private func sampleBuffer(values: [Int16], sampleRate: Int, channels: Int, startFrame: Int = 0) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 2), mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 2),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description)
        guard status == noErr, let description else { throw FixtureError.coreMedia("format", status) }
        let bytes = values.withUnsafeBytes { Data($0) }
        var block: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw FixtureError.coreMedia("block", status) }
        status = bytes.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard status == noErr else { throw FixtureError.coreMedia("copy", status) }
        var sample: CMSampleBuffer?
        // A nonzero source timestamp also checks that startSession does not
        // insert an unwanted prefix before the first microphone buffer.
        let time = CMTime(value: Int64(37 * sampleRate + startFrame), timescale: Int32(sampleRate))
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: description, sampleCount: values.count / channels, presentationTimeStamp: time,
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw FixtureError.coreMedia("sample", status) }
        return sample
    }

    private func finish(_ fixture: Fixture) async -> PCMRecordingWriter.Outcome {
        await withCheckedContinuation { continuation in
            let delivered = CaptureCompletionGate()
            fixture.writer.finish { outcome in
                if delivered.claim() { continuation.resume(returning: outcome) }
            }
            let staging = fixture.staging
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if delivered.claim() {
                    continuation.resume(returning: .failed("Synthetic CAF finalization exceeded the test deadline.", staging))
                }
            }
        }
    }

    private func decoded(_ url: URL, sampleRate: Int, channels: Int, expected: [Int16], file: StaticString = #filePath, line: UInt = #line) throws {
        let audio = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        XCTAssertEqual(audio.fileFormat.sampleRate, Double(sampleRate), file: file, line: line)
        XCTAssertEqual(audio.fileFormat.channelCount, AVAudioChannelCount(channels), file: file, line: line)
        XCTAssertEqual(audio.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatLinearPCM, file: file, line: line)
        XCTAssertEqual(audio.length, AVAudioFramePosition(expected.count / channels), file: file, line: line)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)) else {
            throw FixtureError.noBuffer
        }
        try audio.read(into: buffer)
        XCTAssertEqual(buffer.frameLength, AVAudioFrameCount(expected.count / channels), file: file, line: line)
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        XCTAssertEqual(buffers.count, 1, file: file, line: line)
        guard let bytes = buffers.first?.mData else { throw FixtureError.noBuffer }
        let actual = Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: Int16.self), count: Int(buffer.frameLength) * channels))
        XCTAssertEqual(actual, expected, "Decoded PCM must preserve every sample and channel position.", file: file, line: line)
    }

    private func appendGenerated(_ fixture: Fixture, sampleRate: Int, channels: Int, silence: Bool = false) async throws -> [Int16] {
        let framesPerBuffer = sampleRate / 100
        var expected: [Int16] = []
        for chunk in 0..<12 {
            let start = chunk * framesPerBuffer
            var values: [Int16] = []
            for frame in start..<(start + framesPerBuffer) {
                for channel in 0..<channels {
                    let value = channel == 0 ? ((frame * 7) % 301 - 150) * 100 : ((frame * 3) % 127 - 63) * 300
                    values.append(silence ? 0 : Int16(value))
                }
            }
            expected.append(contentsOf: values)
            let first = try fixture.writer.append(sampleBuffer(values: values, sampleRate: sampleRate, channels: channels, startFrame: start))
            XCTAssertEqual(first, chunk == 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.published.path))
            // Feed real-time buffers at their represented cadence. Production
            // backpressure handling is exercised unchanged, without polling or
            // retrying an append that the production writer would reject.
            try await Task.sleep(for: .milliseconds(10))
        }
        return expected
    }

    private func assertSaved(_ result: PCMRecordingWriter.Outcome, fixture: Fixture, sampleRate: Int, channels: Int, expected: [Int16]) throws {
        guard case let .saved(url, duration) = result else { throw FixtureError.unexpectedOutcome(String(describing: result)) }
        XCTAssertEqual(url, fixture.published)
        XCTAssertEqual(duration, Double(expected.count / channels) / Double(sampleRate), accuracy: 0.000_001)
        XCTAssertTrue(fixture.gate.isCompleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.published.path))
        try decoded(url, sampleRate: sampleRate, channels: channels, expected: expected)
    }

    func test48000HzStereoPreservesFramesChannelsAndDecodedSamples() async throws {
        let fixture = try fixture()
        let values = try await appendGenerated(fixture, sampleRate: 48_000, channels: 2)
        try assertSaved(await finish(fixture), fixture: fixture, sampleRate: 48_000, channels: 2, expected: values)
    }

    func test16000HzMonoPreservesFramesAndDecodedSamples() async throws {
        let fixture = try fixture()
        let values = try await appendGenerated(fixture, sampleRate: 16_000, channels: 1)
        try assertSaved(await finish(fixture), fixture: fixture, sampleRate: 16_000, channels: 1, expected: values)
    }

    func testValidSilenceIsSavedWithoutARecordingThreshold() async throws {
        let fixture = try fixture()
        let values = try await appendGenerated(fixture, sampleRate: 16_000, channels: 1, silence: true)
        try assertSaved(await finish(fixture), fixture: fixture, sampleRate: 16_000, channels: 1, expected: values)
    }

    func testEmptyInputPublishesNoAudio() async throws {
        let fixture = try fixture()
        guard case .empty = await finish(fixture) else { return XCTFail("Empty input must not be reported as a saved recording.") }
        XCTAssertTrue(fixture.gate.isCompleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.published.path))
    }

    func testFormatChangeRejectsNewBufferAndPreservesValidPrefix() async throws {
        let fixture = try fixture()
        let values = Array(repeating: Int16(1_234), count: 160)
        try fixture.writer.append(sampleBuffer(values: values, sampleRate: 16_000, channels: 1))
        XCTAssertThrowsError(try fixture.writer.append(sampleBuffer(values: Array(repeating: 2_345, count: 960),
            sampleRate: 48_000, channels: 2, startFrame: 480))) { error in
                XCTAssertTrue(error.localizedDescription.contains("format changed"))
            }
        XCTAssertEqual(fixture.writer.progress.frames, 160)
        try assertSaved(await finish(fixture), fixture: fixture, sampleRate: 16_000, channels: 1, expected: values)
    }

    func testDeniedCompletionClosesButCannotPublishTheStagingFile() async throws {
        let fixture = try fixture()
        let values = Array(repeating: Int16(-321), count: 160)
        try fixture.writer.append(sampleBuffer(values: values, sampleRate: 16_000, channels: 1))
        XCTAssertTrue(fixture.gate.claim())
        guard case .suppressed = await finish(fixture) else { return XCTFail("A prior completion owner must suppress publication.") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.published.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staging.path))
        try decoded(fixture.staging, sampleRate: 16_000, channels: 1, expected: values)
    }

    func testDestinationCollisionPreservesBothExistingFileAndFinalizedStaging() async throws {
        let fixture = try fixture()
        let existing = Data("existing destination must not be replaced".utf8)
        try existing.write(to: fixture.published)
        let values = Array(repeating: Int16(987), count: 160)
        try fixture.writer.append(sampleBuffer(values: values, sampleRate: 16_000, channels: 1))
        guard case let .failed(message, recovery) = await finish(fixture) else { return XCTFail("A destination collision must report failure.") }
        XCTAssertTrue(message.contains("could not be moved"))
        XCTAssertEqual(recovery, fixture.staging)
        XCTAssertTrue(fixture.gate.isCompleted, "Publication failure already owns completion; the backend must not claim again.")
        XCTAssertEqual(try Data(contentsOf: fixture.published), existing)
        try decoded(fixture.staging, sampleRate: 16_000, channels: 1, expected: values)
    }
}
