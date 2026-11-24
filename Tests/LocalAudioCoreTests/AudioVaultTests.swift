import XCTest
import AVFoundation
@testable import LocalAudioCore

final class AudioVaultTests: XCTestCase, @unchecked Sendable {
    func fixture() async throws -> (URL, RecordingLibrary, AudioRecording) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAudio-vault-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
        buffer.frameLength = 32_000
        for channel in 0..<2 {
            for frame in 0..<32_000 { buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 0.1) * (channel == 0 ? 0.1 : -0.2)) }
        }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let library = RecordingLibrary(folder: root)
        let item = try await library.registerSaved(url)
        try PrivateJSON.write(LocalTranscript(text: "Keep this text", segments: []), to: item.transcriptURL)
        return (root, library, item)
    }
    func fakeTrash(_ root: URL) -> @Sendable (URL) throws -> URL {
        { url in
            let target = root.appendingPathComponent(".fake-trash-" + UUID().uuidString + ".caf")
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }
    func testTrashKeepsTextDiscoverableAndRestoreVerifiesAudio() async throws {
        let (root, library, item) = try await fixture()
        let hash = try RecordingLibrary.hash(item.url)
        try await library.trashAudio(item, protectedIDs: [], trash: fakeTrash(root))
        var scan = try await library.scan()
        XCTAssertEqual(scan.count, 1)
        XCTAssertFalse(scan[0].hasAudio)
        XCTAssertEqual(scan[0].duration, 2)
        XCTAssertEqual(scan[0].bytes, 0)
        XCTAssertEqual(try PrivateJSON.read(LocalTranscript.self, from: scan[0].transcriptURL).text, "Keep this text")
        try await library.restoreAudio(scan[0])
        scan = try await library.scan()
        XCTAssertTrue(scan[0].hasAudio)
        XCTAssertNil(scan[0].metadata.audioRemovedAt)
        XCTAssertEqual(try RecordingLibrary.hash(scan[0].url), hash)
    }
    func testPassageHasExactFramesStereoSamplesAndSurvivesParentRemoval() async throws {
        let (root, library, item) = try await fixture()
        let originalHash = try RecordingLibrary.hash(item.url)
        let clip = try await library.savePassage(item, start: 0.25, end: 1.125, title: "A keeper")
        XCTAssertEqual(clip.duration, 0.875, accuracy: 0.000_001)
        XCTAssertEqual(clip.metadata.clipSourceID, item.id)
        XCTAssertNotNil(clip.metadata.vaultedAt)
        XCTAssertEqual(clip.metadata.clipStart, 0.25)
        XCTAssertEqual(clip.metadata.clipEnd, 1.125)
        let audio = try AVAudioFile(forReading: clip.url)
        XCTAssertEqual(audio.length, 14_000)
        XCTAssertEqual(audio.processingFormat.channelCount, 2)
        let data = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 14_000))
        try audio.read(into: data)
        for channel in 0..<2 {
            for frame in stride(from: 0, to: 14_000, by: 199) {
                XCTAssertEqual(data.floatChannelData![channel][frame], Float(sin(Double(frame + 4_000) * 0.1) * (channel == 0 ? 0.1 : -0.2)), accuracy: 0.000_001)
            }
        }
        XCTAssertEqual(try RecordingLibrary.hash(item.url), originalHash)
        let clipHash = try RecordingLibrary.hash(clip.url)
        try await library.trashAudio(item, protectedIDs: [], trash: fakeTrash(root))
        let scan = try await library.scan()
        XCTAssertEqual(scan.count, 2)
        XCTAssertEqual(try RecordingLibrary.hash(clip.url), clipHash)
        XCTAssertTrue(scan.first { $0.id == clip.id }!.hasAudio)
    }
    func testVaultVoiceAndQueuedProtectionMissingTranscriptAndStaleSnapshotFailClosed() async throws {
        let (root, library, item) = try await fixture()
        do { try await library.trashAudio(item, protectedIDs: [item.id], trash: fakeTrash(root)); XCTFail("Protected audio removed") } catch {}
        try await library.setVaulted(item, true)
        let vaulted = try await library.describe(item.url)
        do { try await library.trashAudio(vaulted, protectedIDs: [], trash: fakeTrash(root)); XCTFail("Vault removed") } catch {}
        do { try await library.trashAudio(item, protectedIDs: [], trash: fakeTrash(root)); XCTFail("Stale snapshot removed") } catch {}
        try await library.setVaulted(vaulted, false)
        let unvaulted = try await library.describe(item.url)
        try FileManager.default.removeItem(at: item.transcriptURL)
        do { try await library.trashAudio(unvaulted, protectedIDs: [], trash: fakeTrash(root)); XCTFail("Untranscribed audio removed") } catch {}
        try Data("corrupt".utf8).write(to: item.transcriptURL)
        do { try await library.trashAudio(unvaulted, protectedIDs: [], trash: fakeTrash(root)); XCTFail("Corrupt transcript accepted") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
    }
    func testTrashFailureRollsBackReceiptAndLeavesAudio() async throws {
        let (_, library, item) = try await fixture()
        do {
            try await library.trashAudio(item, protectedIDs: [], trash: { _ in throw LocalAudioError.message("Test failure") })
            XCTFail("Failure not reported")
        } catch {}
        let current = try await library.describe(item.url)
        XCTAssertEqual(current, item)
    }
    func testInterruptedMoveReceiptKeepsTranscriptAndCanRecoverExistingAudio() async throws {
        let (_, library, item) = try await fixture()
        var metadata = item.metadata
        metadata.audioRemovedAt = Date(); metadata.retainedDuration = item.duration
        metadata.removedAudioHash = try RecordingLibrary.hash(item.url)
        try PrivateJSON.write(metadata, to: AudioRecording.metadataURL(for: item.url))
        let current = try await library.describe(item.url)
        try await library.restoreAudio(current)
        let restored = try await library.describe(item.url)
        XCTAssertNil(restored.metadata.audioRemovedAt)
        XCTAssertTrue(restored.hasAudio)
    }
    func testInvalidRangesAndOutsideFolderNeverChangeOriginal() async throws {
        let (_, library, item) = try await fixture()
        let hash = try RecordingLibrary.hash(item.url)
        for (start, end) in [(-1.0, 1.0), (1, 0), (0, 3), (.nan, 1), (0, .infinity)] {
            do { _ = try await library.savePassage(item, start: start, end: end, title: "Bad"); XCTFail("Invalid range accepted") } catch {}
        }
        let foreign = RecordingLibrary(folder: item.url.deletingLastPathComponent().appendingPathComponent("Other"))
        do { try await foreign.trashAudio(item, protectedIDs: [], trash: { _ in XCTFail("Trash called for foreign path"); return item.url }); XCTFail("Foreign file accepted") } catch {}
        XCTAssertEqual(try RecordingLibrary.hash(item.url), hash)
    }
    func testEditedRecordingDateDoesNotChangeRetentionAgeAndLegacyGetsGrace() async throws {
        let (_, library, item) = try await fixture()
        let enabled = Date(timeIntervalSince1970: 1_000)
        let policy = AudioRetention(days: 7, enabledAt: enabled)
        var legacy = item
        legacy.metadata.managedAt = enabled; legacy.metadata.recordedAt = .distantPast
        XCTAssertFalse(policy.isDue(legacy, now: enabled.addingTimeInterval(7 * 86_400 - 1)))
        XCTAssertTrue(policy.isDue(legacy, now: enabled.addingTimeInterval(7 * 86_400)))
        legacy.metadata.recordedAt = .distantFuture
        XCTAssertTrue(policy.isDue(legacy, now: enabled.addingTimeInterval(8 * 86_400)))
        legacy.metadata.vaultedAt = Date()
        XCTAssertFalse(policy.isDue(legacy, now: .distantFuture))
        try await library.update(item, title: "Edited", date: .distantPast)
        let updated = try await library.describe(item.url)
        XCTAssertEqual(updated.metadata.managedAt, item.metadata.managedAt)
    }
    func testUnknownEntryAgeIsAdoptedWithFreshWindowAndNeverImmediatelyExpires() async throws {
        let (_, library, item) = try await fixture()
        var metadata = item.metadata; metadata.managedAt = nil
        try PrivateJSON.write(metadata, to: AudioRecording.metadataURL(for: item.url))
        let old = AudioRetention(days: 7, enabledAt: .distantPast)
        let unknown = try await library.describe(item.url)
        XCTAssertFalse(old.isDue(unknown))
        let now = Date()
        try await library.adoptAudioForRetention(now: now)
        let adopted = try await library.describe(item.url)
        XCTAssertEqual(adopted.metadata.managedAt, now)
        XCTAssertFalse(old.isDue(adopted, now: now))
        XCTAssertTrue(old.isDue(adopted, now: now.addingTimeInterval(7 * 86_400)))
    }
    func testSymlinkedVaultOrTranscriptCannotEscapeLibrary() async throws {
        let (root, library, item) = try await fixture()
        let outside = root.deletingLastPathComponent().appendingPathComponent("LocalAudio-outside-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Vault"), withDestinationURL: outside)
        do { _ = try await library.savePassage(item, start: 0, end: 1, title: "Escape"); XCTFail("Vault symlink accepted") } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        let text = outside.appendingPathComponent("text.json")
        try FileManager.default.moveItem(at: item.transcriptURL, to: text)
        try FileManager.default.createSymbolicLink(at: item.transcriptURL, withDestinationURL: text)
        do { try await library.trashAudio(item, protectedIDs: [], trash: fakeTrash(root)); XCTFail("Transcript symlink accepted") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
    }
    func testReceiptSurvivesMoveThenFailureAndMissingTrashDoesNotLoseText() async throws {
        let (root, library, item) = try await fixture()
        do {
            try await library.trashAudio(item, protectedIDs: [], trash: { url in
                try FileManager.default.moveItem(at: url, to: root.appendingPathComponent(".interrupted-trash.caf"))
                throw LocalAudioError.message("Interrupted after move")
            })
            XCTFail("Failure not reported")
        } catch {}
        let scan = try await library.scan()
        XCTAssertEqual(scan.count, 1); XCTAssertFalse(scan[0].hasAudio)
        XCTAssertNotNil(scan[0].metadata.audioRemovedAt)
        do { try await library.restoreAudio(scan[0]); XCTFail("Missing receipt location restored") } catch {}
        XCTAssertEqual(try PrivateJSON.read(LocalTranscript.self, from: item.transcriptURL).text, "Keep this text")
    }

    func testChangedTrashAudioCannotBeRestoredOverOriginalLocation() async throws {
        let (root, library, item) = try await fixture()
        try await library.trashAudio(item, protectedIDs: [], trash: fakeTrash(root))
        let removed = try await library.describe(item.url)
        let trash = try XCTUnwrap(removed.metadata.trashedAudioURL)
        try Data("Different bytes".utf8).write(to: trash)
        do { try await library.restoreAudio(removed); XCTFail("Modified Trash audio restored") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
        XCTAssertEqual(try PrivateJSON.read(LocalTranscript.self, from: item.transcriptURL).text, "Keep this text")
        let scan = try await library.scan()
        XCTAssertEqual(scan.count, 1)
    }

    func testReimportAfterAudioRemovalCopiesSourceInsteadOfReturningMissingAudio() async throws {
        let (root, _, original) = try await fixture()
        let library = RecordingLibrary(folder: root.appendingPathComponent("Imported"))
        let first = try await library.importAudio(original.url)
        try PrivateJSON.write(LocalTranscript(text: "Imported text", segments: []), to: first.transcriptURL)
        try await library.trashAudio(first, protectedIDs: [], trash: fakeTrash(root))
        let importedAgain = try await library.importAudio(original.url)
        XCTAssertTrue(importedAgain.hasAudio)
        XCTAssertNotEqual(importedAgain.id, first.id)
        XCTAssertEqual(try RecordingLibrary.hash(importedAgain.url), try RecordingLibrary.hash(original.url))
        let scan = try await library.scan()
        XCTAssertEqual(scan.count, 2)
        XCTAssertEqual(try PrivateJSON.read(LocalTranscript.self, from: first.transcriptURL).text, "Imported text")
    }

}
