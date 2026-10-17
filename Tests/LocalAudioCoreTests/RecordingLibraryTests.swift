import XCTest
import AVFoundation
@testable import LocalAudioCore

final class RecordingLibraryTests: XCTestCase, @unchecked Sendable {
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAudio-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func audio(at url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        for index in 0..<16_000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.1) * 0.1) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    func testImportCopiesPreservesSourceAndDeduplicatesByContent() async throws {
        let root = try temporary(), source = root.appendingPathComponent("source.wav")
        try audio(at: source)
        let before = try Data(contentsOf: source)
        let library = RecordingLibrary(folder: root.appendingPathComponent("Library"))
        let first = try await library.importAudio(source)
        let second = try await library.importAudio(source)
        XCTAssertEqual(first.id, second.id)
        XCTAssertNotEqual(first.url, source)
        XCTAssertEqual(try Data(contentsOf: first.url), before)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(first.duration, 1, accuracy: 0.001)
        XCTAssertEqual(first.metadata.importedFrom, "source.wav")
        let scanned = try await library.scan()
        XCTAssertEqual(scanned.count, 1)
        let mode = try FileManager.default.attributesOfItem(atPath: first.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testChangingDetailsOnlyChangesSidecar() async throws {
        let root = try temporary(), url = root.appendingPathComponent("sample.caf")
        try audio(at: url)
        let hash = try RecordingLibrary.hash(url)
        let library = RecordingLibrary(folder: root)
        let first = try await library.registerSaved(url)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await library.update(first, title: "Interview", date: date)
        let changed = try await library.describe(url)
        XCTAssertEqual(changed.id, first.id)
        XCTAssertEqual(changed.title, "Interview")
        XCTAssertEqual(changed.date, date)
        XCTAssertEqual(try RecordingLibrary.hash(url), hash)
    }

    func testSameStemDifferentFormatsHaveIndependentSidecars() {
        let wav = URL(fileURLWithPath: "/example/take.wav"), caf = URL(fileURLWithPath: "/example/take.caf")
        XCTAssertNotEqual(AudioRecording.metadataURL(for: wav), AudioRecording.metadataURL(for: caf))
        XCTAssertNotEqual(AudioRecording.transcriptURL(for: wav), AudioRecording.transcriptURL(for: caf))
        XCTAssertNotEqual(AudioRecording.metadataURL(for: wav), wav)
    }

    func testCorruptFileAndMetadataAreReportedAndPreserved() async throws {
        let root = try temporary(), good = root.appendingPathComponent("good.wav"), bad = root.appendingPathComponent("bad.wav")
        try audio(at: good)
        try Data("invalid".utf8).write(to: bad)
        let library = RecordingLibrary(folder: root)
        var scan = try await library.scanWithWarnings()
        XCTAssertEqual(scan.recordings.count, 1)
        XCTAssertEqual(scan.warnings.count, 1)
        let metadata = AudioRecording.metadataURL(for: good)
        try Data("broken json".utf8).write(to: metadata)
        scan = try await library.scanWithWarnings()
        XCTAssertEqual(scan.recordings.count, 0)
        XCTAssertEqual(scan.warnings.count, 2)
        XCTAssertEqual(try String(contentsOf: metadata, encoding: .utf8), "broken json")
        XCTAssertEqual(try String(contentsOf: bad, encoding: .utf8), "invalid")
    }

    func testMissingFolderIsEmptyAndFileAsFolderIsAnError() async throws {
        let root = try temporary(), missing = root.appendingPathComponent("missing")
        let empty = try await RecordingLibrary(folder: missing).scan()
        XCTAssertTrue(empty.isEmpty)
        try Data().write(to: missing)
        do { _ = try await RecordingLibrary(folder: missing).scan(); XCTFail("File accepted as directory") } catch {}
    }

    func testCopiedMetadataIdentityIsReportedWithoutMergingOrRewriting() async throws {
        let root = try temporary(), first = root.appendingPathComponent("one.caf"), second = root.appendingPathComponent("two.caf")
        try audio(at: first)
        let library = RecordingLibrary(folder: root)
        _ = try await library.registerSaved(first)
        try FileManager.default.copyItem(at: first, to: second)
        let firstMetadata = AudioRecording.metadataURL(for: first), secondMetadata = AudioRecording.metadataURL(for: second)
        try FileManager.default.copyItem(at: firstMetadata, to: secondMetadata)
        let scan = try await library.scanWithWarnings()
        XCTAssertEqual(scan.recordings.count, 1)
        XCTAssertEqual(scan.warnings.count, 1)
        XCTAssertTrue(scan.warnings[0].contains("duplicate recording identity"))
        XCTAssertEqual(try Data(contentsOf: firstMetadata), try Data(contentsOf: secondMetadata))
    }

    func testTranscriptAndQueueRoundTripWithoutAudioMutation() async throws {
        let root = try temporary(), url = root.appendingPathComponent("a.caf")
        try audio(at: url)
        let item = try await RecordingLibrary(folder: root).describe(url)
        let transcript = LocalTranscript(text: "Hello.", segments: [.init(id: 0, start: 0.2, end: 0.8, text: "Hello.")])
        try PrivateJSON.write(transcript, to: item.transcriptURL)
        XCTAssertEqual(try PrivateJSON.read(LocalTranscript.self, from: item.transcriptURL), transcript)
        let jobsURL = root.appendingPathComponent("jobs.json")
        let job = TranscriptionJob(recording: item)
        try PrivateJSON.write([job], to: jobsURL)
        XCTAssertEqual(try PrivateJSON.read([TranscriptionJob].self, from: jobsURL), [job])
        XCTAssertTrue(transcript.exportedText(title: "Test", recordedAt: item.date).contains("Hello."))
    }

    func testLaunchOverridesAreExplicitAndMalformedOptionsFail() throws {
        let home = URL(fileURLWithPath: "/testing/home")
        let normal = try LaunchPaths.parse([], home: home)
        XCTAssertFalse(normal.isIsolated)
        XCTAssertEqual(normal.data.path, "/testing/home/Library/Application Support/LocalAudio")
        let isolated = try LaunchPaths.parse(["--data-folder", "/tmp/isolated", "--recordings-folder", "/tmp/audio"], home: home)
        XCTAssertTrue(isolated.isIsolated)
        XCTAssertEqual(isolated.recordingsOverride?.path, "/tmp/audio")
        for arguments in [["--data-folder"], ["--bad", "x"], ["--data-folder", ""], ["--data-folder", "x", "--data-folder", "y"]] {
            XCTAssertThrowsError(try LaunchPaths.parse(arguments, home: home))
        }
    }
}
