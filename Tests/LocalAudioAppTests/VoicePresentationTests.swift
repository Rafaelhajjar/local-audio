import AVFoundation
import XCTest
import LocalAudioCore
@testable import LocalAudioApp

@MainActor
final class VoicePresentationTests: XCTestCase {
    private func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAudio-voice-presentation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func recording(in folder: URL, value: Float) async throws -> AudioRecording {
        let audio = folder.appendingPathComponent(UUID().uuidString + ".caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        buffer.frameLength = 96_000
        buffer.floatChannelData![0].initialize(repeating: value, count: 96_000)
        do {
            let writer = try AVAudioFile(forWriting: audio, settings: format.settings)
            try writer.write(from: buffer)
        }
        return try await RecordingLibrary(folder: folder).registerSaved(audio)
    }

    private func prepare(_ item: AudioRecording, bank: VoiceLibrary) async throws -> VoiceAnalysis {
        let request = try await bank.analysisRequest(for: item, modelID: ModelPack.speakers.modelID)
        var x = [Float](repeating: 0, count: 256), y = x
        x[0] = 1; y[1] = 1
        let turns = [VoiceTurn(id: "one", start: 0, end: 2.5, speakerID: "S1", embedding: x, sampleStart: 0, sampleEnd: 2.5),
                     VoiceTurn(id: "two", start: 3, end: 6, speakerID: "S2", embedding: y, sampleStart: 3, sampleEnd: 6)]
        return try await bank.saveAnalysis(VoiceAnalysis(recordingID: item.id, audioHash: request.audioHash,
            modelID: request.modelID, turns: turns), for: item)
    }

    func testTranscriptChunksAbstainForUnknownMixedAndInsufficientCoverage() async throws {
        let folder = try fixture(), bank = VoiceLibrary(folder: folder.appendingPathComponent("Voices"))
        let item = try await recording(in: folder, value: 0.1)
        _ = try await prepare(item, bank: bank)
        let alice = try await bank.createPerson(name: "Alice")
        _ = try await bank.confirm(turnID: "one", in: item, personID: alice.id)
        let controller = VoiceController(dataFolder: folder)
        await controller.reloadProfiles(); await controller.select(item)
        XCTAssertEqual(controller.confirmedName(start: 0, end: 2), "Alice")
        XCTAssertNil(controller.confirmedName(start: 0, end: 6), "A chunk containing Unknown speech must never inherit a nearby name.")
        XCTAssertNil(controller.confirmedName(start: 0, end: 3), "A large uncovered portion must remain Unknown.")
        let bob = try await bank.createPerson(name: "Bob")
        _ = try await bank.confirm(turnID: "two", in: item, personID: bob.id)
        await controller.reloadProfiles(); await controller.select(item)
        XCTAssertNil(controller.confirmedName(start: 0, end: 6), "A mixed-speaker chunk cannot receive either person's name.")
        XCTAssertEqual(controller.confirmedName(start: 3, end: 5), "Bob")
    }

    func testCrossRecordingSuggestionCannotNameExportOrEnrollUntilConfirmed() async throws {
        let folder = try fixture(), bank = VoiceLibrary(folder: folder.appendingPathComponent("Voices"))
        let first = try await recording(in: folder, value: 0.1)
        let second = try await recording(in: folder, value: 0.2)
        _ = try await prepare(first, bank: bank)
        let next = try await prepare(second, bank: bank)
        let alice = try await bank.createPerson(name: "Alice")
        _ = try await bank.confirm(turnID: "one", in: first, personID: alice.id)
        let controller = VoiceController(dataFolder: folder)
        await controller.reloadProfiles(); await controller.select(second)
        XCTAssertEqual(controller.suggestion(for: next.turns[0])?.personID, alice.id)
        XCTAssertEqual(controller.personName(for: next.turns[0]), "Unknown")
        let transcript = LocalTranscript(text: "Hello there.", segments: [.init(id: 0, start: 0, end: 2, text: "Hello there.")])
        let unconfirmedExport = controller.exportedText(transcript, item: second)
        XCTAssertTrue(unconfirmedExport.contains("Unknown: Hello there."))
        XCTAssertFalse(unconfirmedExport.contains("Alice"))
        XCTAssertEqual(controller.profiles.first?.examples.count, 1)
        await controller.confirm(next.turns[0], in: second, personID: alice.id)
        XCTAssertNil(controller.error)
        XCTAssertEqual(controller.profiles.first?.examples.count, 2)
        XCTAssertTrue(controller.exportedText(transcript, item: second).contains("Alice: Hello there."))
        await controller.unconfirm(next.turns[0], in: second)
        XCTAssertEqual(controller.profiles.first?.examples.count, 1)
        XCTAssertTrue(controller.exportedText(transcript, item: second).contains("Unknown: Hello there."))
    }

    func testNamedExportRejectsAudioChangedAfterSelection() async throws {
        let folder = try fixture(), bank = VoiceLibrary(folder: folder.appendingPathComponent("Voices"))
        let item = try await recording(in: folder, value: 0.5)
        let analysis = try await prepare(item, bank: bank)
        let controller = VoiceController(dataFolder: folder)
        await controller.select(item)
        await controller.name(analysis.turns[0], in: item, newName: "Alice")
        let transcript = LocalTranscript(text: "Hello.", segments: [.init(id: 0, start: 0, end: 2, text: "Hello.")])
        let valid = try await controller.validatedExportedText(transcript, item: item)
        XCTAssertTrue(valid.contains("Alice: Hello."))
        try Data("changed audio".utf8).write(to: item.url)
        do {
            _ = try await controller.validatedExportedText(transcript, item: item)
            XCTFail("A changed source must not export cached identities.")
        } catch { }
        XCTAssertNil(controller.analysis)
    }

    func testStaleNamingSheetCannotNameAReplacementTurnOrCreateAPerson() async throws {
        let folder = try fixture(), bank = VoiceLibrary(folder: folder.appendingPathComponent("Voices"))
        let item = try await recording(in: folder, value: 0.4)
        let reviewed = try await prepare(item, bank: bank)
        let controller = VoiceController(dataFolder: folder)
        await controller.select(item)
        var replacement = reviewed
        replacement.createdAt = reviewed.createdAt.addingTimeInterval(1)
        replacement.turns[0].end = 2.8
        _ = try await bank.saveAnalysis(replacement, for: item)
        await controller.select(item)
        await controller.name(reviewed.turns[0], in: item, newName: "Stale Name", expected: reviewed)
        XCTAssertNotNil(controller.error)
        let profiles = try await bank.profiles()
        let current = try await bank.loadAnalysis(for: item)
        XCTAssertTrue(profiles.isEmpty)
        XCTAssertNil(current?.turns[0].confirmedPersonID)
    }

    func testNameRenameRelaunchAndForgetPreserveAudioAndRevokeIdentity() async throws {
        let folder = try fixture(), bank = VoiceLibrary(folder: folder.appendingPathComponent("Voices"))
        let item = try await recording(in: folder, value: 0.3)
        let analysis = try await prepare(item, bank: bank)
        let audioHash = try RecordingLibrary.hash(item.url)
        let controller = VoiceController(dataFolder: folder)
        await controller.select(item)
        await controller.name(analysis.turns[0], in: item, newName: "First Name")
        XCTAssertNil(controller.error)
        let person = try XCTUnwrap(controller.profiles.first)
        await controller.rename(person, to: "Updated Name")
        let relaunched = VoiceController(dataFolder: folder)
        await relaunched.reloadProfiles(); await relaunched.select(item)
        XCTAssertEqual(relaunched.confirmedName(start: 0, end: 2), "Updated Name")
        await relaunched.forget(try XCTUnwrap(relaunched.profiles.first))
        XCTAssertTrue(relaunched.profiles.isEmpty)
        XCTAssertNil(relaunched.confirmedName(start: 0, end: 2))
        XCTAssertEqual(try RecordingLibrary.hash(item.url), audioHash)
    }
}
