import XCTest
import AVFoundation
@testable import LocalAudioCore

@MainActor
final class VoiceLibraryTests: XCTestCase {
    private let model = "speakers-community-1@test-revision"

    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAudio-voices-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func generatedAudio(at url: URL, frequency: Double = 0.07) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        buffer.frameLength = 96_000
        for index in 0..<96_000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * frequency) * 0.1) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func recording(_ root: URL, name: String = "generated.wav") async throws -> AudioRecording {
        let url = root.appendingPathComponent(name)
        try generatedAudio(at: url)
        return try await RecordingLibrary(folder: root).registerSaved(url)
    }

    private func vector(_ first: Float = 1, _ second: Float = 0) -> [Float] {
        [first, second] + Array(repeating: 0, count: 254)
    }

    private func analysis(_ recording: AudioRecording, embedding: [Float]? = nil) throws -> VoiceAnalysis {
        VoiceAnalysis(recordingID: recording.id, audioHash: try RecordingLibrary.hash(recording.url), modelID: model,
            turns: [VoiceTurn(id: "turn-1", start: 0, end: 4, speakerID: "speaker_0",
                              embedding: embedding ?? vector(), sampleStart: 0.5, sampleEnd: 3.5)])
    }

    private func expectFailure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected a preserving failure", file: file, line: line) } catch {}
    }

    func testExplicitConfirmationPersistsWithoutWritingIdentityIntoHelperSidecar() async throws {
        let root = try temporary(), item = try await recording(root)
        let folder = root.appendingPathComponent("Private")
        let library = VoiceLibrary(folder: folder)
        let person = try await library.createPerson(name: "  Alex  ")
        var raw = try analysis(item, embedding: vector(3, 4))
        raw.turns[0].confirmedPersonID = person.id // untrusted helper field
        let anonymous = try await library.saveAnalysis(raw, for: item)
        XCTAssertNil(anonymous.turns[0].confirmedPersonID)
        var profiles = try await library.profiles()
        XCTAssertTrue(profiles[0].examples.isEmpty)
        let confirmed = try await library.confirm(turnID: "turn-1", in: item, personID: person.id)
        XCTAssertEqual(confirmed.turns[0].confirmedPersonID, person.id)
        let restarted = VoiceLibrary(folder: folder)
        profiles = try await restarted.profiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].name, "Alex")
        let example = try XCTUnwrap(profiles[0].examples.first)
        XCTAssertEqual(example.audioHash, raw.audioHash)
        XCTAssertEqual(example.start, 0.5)
        XCTAssertEqual(example.end, 3.5)
        XCTAssertEqual(example.embedding[0], 0.6, accuracy: 0.00001)
        XCTAssertEqual(example.embedding[1], 0.8, accuracy: 0.00001)
        let restored = try await restarted.loadAnalysis(for: item)
        XCTAssertEqual(restored?.turns[0].confirmedPersonID, person.id)
        let sidecar = VoiceLibrary.analysisURL(for: item.url)
        XCTAssertEqual(sidecar.lastPathComponent, "generated.wav.voices.json")
        let storedRaw = try JSONDecoder().decode(VoiceAnalysis.self, from: Data(contentsOf: sidecar))
        XCTAssertNil(storedRaw.turns[0].confirmedPersonID)
        for url in [sidecar, folder.appendingPathComponent("voice-library.json")] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
        }
    }

    func testReassignUnconfirmRenameAndDeleteRevokeExamples() async throws {
        let root = try temporary(), item = try await recording(root)
        let library = VoiceLibrary(folder: root.appendingPathComponent("Private"))
        let first = try await library.createPerson(name: "First"), second = try await library.createPerson(name: "Second")
        try await library.saveAnalysis(analysis(item), for: item)
        try await library.confirm(turnID: "turn-1", in: item, personID: first.id)
        try await library.confirm(turnID: "turn-1", in: item, personID: second.id)
        var people = try await library.profiles()
        XCTAssertTrue(people.first { $0.id == first.id }!.examples.isEmpty)
        XCTAssertEqual(people.first { $0.id == second.id }!.examples.count, 1)
        let renamed = try await library.renamePerson(id: second.id, name: "Renamed")
        XCTAssertEqual(renamed.name, "Renamed")
        XCTAssertEqual(renamed.examples.count, 1)
        let cleared = try await library.unconfirm(turnID: "turn-1", in: item)
        XCTAssertNil(cleared.turns[0].confirmedPersonID)
        people = try await library.profiles()
        XCTAssertTrue(people.allSatisfy { $0.examples.isEmpty })
        try await library.confirm(turnID: "turn-1", in: item, personID: second.id)
        try await library.deletePerson(id: second.id)
        let loaded = try await library.loadAnalysis(for: item)
        XCTAssertNil(loaded?.turns[0].confirmedPersonID)
        people = try await library.profiles()
        XCTAssertEqual(people.map(\.id), [first.id])
    }

    func testShortMissingAndMalformedVectorsCanBeLabeledButNeverEnrolled() async throws {
        let root = try temporary(), item = try await recording(root)
        let library = VoiceLibrary(folder: root.appendingPathComponent("Private"))
        let person = try await library.createPerson(name: "Alex")
        var raw = try analysis(item)
        raw.turns = [
            VoiceTurn(id: "short", start: 0, end: 0.5, speakerID: "s0", embedding: vector(), sampleStart: 0, sampleEnd: 0.5),
            VoiceTurn(id: "no-vector", start: 0.5, end: 3, speakerID: "s1"),
            VoiceTurn(id: "bad-dimensions", start: 3, end: 6, speakerID: "s2", embedding: [1, 0], sampleStart: 3, sampleEnd: 6),
            VoiceTurn(id: "zero", start: 0, end: 3, speakerID: "s3", embedding: Array(repeating: 0, count: 256), sampleStart: 0, sampleEnd: 3)
        ]
        try await library.saveAnalysis(raw, for: item)
        for turn in raw.turns {
            let confirmed = try await library.confirm(turnID: turn.id, in: item, personID: person.id)
            XCTAssertEqual(confirmed.turns.first { $0.id == turn.id }?.confirmedPersonID, person.id)
        }
        let profiles = try await library.profiles()
        XCTAssertTrue(profiles[0].examples.isEmpty)
    }

    func testMatchingOnlySuggestsAndAbstainsForUnknownAmbiguousOrBadVectors() {
        let raw = VoiceAnalysis(recordingID: "query", audioHash: String(repeating: "a", count: 64), modelID: model,
                                turns: [VoiceTurn(id: "q", start: 0, end: 3, speakerID: "s", embedding: vector(), sampleStart: 0, sampleEnd: 3)])
        let example = VoiceExample(recordingID: "other", audioHash: String(repeating: "b", count: 64), turnID: "old", modelID: model,
                                   start: 0, end: 3, embedding: vector())
        let person = VoiceProfile(name: "Alex", examples: [example])
        let candidate = VoiceMatcher.suggestion(for: raw.turns[0], in: raw, profiles: [person])
        XCTAssertEqual(candidate?.personID, person.id)
        XCTAssertEqual(candidate?.similarity ?? 0, 1, accuracy: 0.000001)
        XCTAssertNil(raw.turns[0].confirmedPersonID)
        XCTAssertEqual(person.examples, [example])
        XCTAssertNil(VoiceMatcher.suggestion(for: raw.turns[0], in: raw, profiles: []))
        let ambiguous = VoiceProfile(name: "Another Alex", examples: [example])
        XCTAssertNil(VoiceMatcher.suggestion(for: raw.turns[0], in: raw, profiles: [person, ambiguous]))
        for embedding in [vector(0, 1), [1, 0], Array(repeating: Float(0), count: 256), vector(.nan), vector(.infinity)] {
            var turn = raw.turns[0]; turn.embedding = embedding
            XCTAssertNil(VoiceMatcher.suggestion(for: turn, in: raw, profiles: [person]))
        }
        var labeled = raw.turns[0]; labeled.confirmedPersonID = person.id
        XCTAssertNil(VoiceMatcher.suggestion(for: labeled, in: raw, profiles: [person]))
    }

    func testMatchingExcludesSameRecordingCopiedAudioAndOtherModel() {
        let hash = String(repeating: "a", count: 64)
        let raw = VoiceAnalysis(recordingID: "query", audioHash: hash, modelID: model,
                                turns: [VoiceTurn(id: "q", start: 0, end: 3, speakerID: "s", embedding: vector(), sampleStart: 0, sampleEnd: 3)])
        for (recordingID, audioHash, modelID) in [
            ("query", String(repeating: "b", count: 64), model),
            ("copied-file-new-id", hash, model),
            ("other", String(repeating: "b", count: 64), "other-model")
        ] {
            let example = VoiceExample(recordingID: recordingID, audioHash: audioHash, turnID: "e", modelID: modelID,
                                       start: 0, end: 3, embedding: vector())
            XCTAssertNil(VoiceMatcher.suggestion(for: raw.turns[0], in: raw, profiles: [VoiceProfile(name: "Alex", examples: [example])]))
        }
    }

    func testMultipleExamplesUseTopTwoDistinctHashesAndRunnerUpMargin() {
        let raw = VoiceAnalysis(recordingID: "query", audioHash: String(repeating: "a", count: 64), modelID: model,
                                turns: [VoiceTurn(id: "q", start: 0, end: 3, speakerID: "s", embedding: vector(), sampleStart: 0, sampleEnd: 3)])
        func example(_ hash: Character, _ cosine: Float) -> VoiceExample {
            VoiceExample(recordingID: String(hash), audioHash: String(repeating: String(hash), count: 64), turnID: "e", modelID: model,
                         start: 0, end: 3, embedding: vector(cosine, sqrt(1 - cosine * cosine)))
        }
        let best = VoiceProfile(name: "Alex", examples: [example("b", 1), example("c", 0.96), example("b", 1)])
        let other = VoiceProfile(name: "Other", examples: [example("d", 0.8)])
        let match = VoiceMatcher.suggestion(for: raw.turns[0], in: raw, profiles: [best, other])
        XCTAssertEqual(match?.similarity ?? 0, 0.98, accuracy: 0.00001)
        XCTAssertEqual(match?.exampleCount, 2)
        let close = VoiceProfile(name: "Close", examples: [example("e", 0.94)])
        XCTAssertNil(VoiceMatcher.suggestion(for: raw.turns[0], in: raw, profiles: [best, close]))
    }

    func testFirstHumanConfirmationCanSuggestOnLaterDistinctAudioWithoutEnrollingIt() async throws {
        let root = try temporary(), first = try await recording(root)
        let secondURL = root.appendingPathComponent("later.wav")
        try generatedAudio(at: secondURL, frequency: 0.19)
        let second = try await RecordingLibrary(folder: root).registerSaved(secondURL)
        let library = VoiceLibrary(folder: root.appendingPathComponent("Private"))
        let person = try await library.createPerson(name: "Alex")
        try await library.saveAnalysis(analysis(first), for: first)
        try await library.confirm(turnID: "turn-1", in: first, personID: person.id)
        let later = try await library.saveAnalysis(analysis(second), for: second)
        let people = try await library.profiles()
        XCTAssertEqual(people[0].examples.count, 1)
        let suggestion = VoiceMatcher.suggestion(for: later.turns[0], in: later, profiles: people)
        XCTAssertEqual(suggestion?.personID, person.id)
        XCTAssertNil(later.turns[0].confirmedPersonID)
        let stillUnknown = try await library.loadAnalysis(for: second)
        XCTAssertNil(stillUnknown?.turns[0].confirmedPersonID)
        let unchangedPeople = try await library.profiles()
        XCTAssertEqual(unchangedPeople.first?.examples.count, 1)
        var tooShort = later.turns[0]; tooShort.sampleEnd = 1
        XCTAssertNil(VoiceMatcher.suggestion(for: tooShort, in: later, profiles: people))
    }

    func testCorruptAndFutureIdentityStorePreservedAndMutationsFailClosed() async throws {
        let root = try temporary(), folder = root.appendingPathComponent("Private")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("voice-library.json")
        for bytes in [Data("broken-json".utf8), Data("{\"version\":2,\"newData\":\"preserve\"}".utf8)] {
            try bytes.write(to: url)
            let library = VoiceLibrary(folder: folder)
            await expectFailure { _ = try await library.profiles() }
            await expectFailure { _ = try await library.createPerson(name: "Alex") }
            await expectFailure { _ = try await library.renamePerson(id: "missing", name: "New") }
            await expectFailure { try await library.deletePerson(id: "missing") }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testCorruptFutureAndInvalidAnalysisArePreserved() async throws {
        let root = try temporary(), item = try await recording(root)
        let library = VoiceLibrary(folder: root.appendingPathComponent("Private"))
        let valid = try analysis(item)
        let sidecar = VoiceLibrary.analysisURL(for: item.url)
        for bytes in [Data("broken-json".utf8), Data("{\"version\":2,\"newData\":\"preserve\"}".utf8)] {
            try bytes.write(to: sidecar)
            await expectFailure { _ = try await library.loadAnalysis(for: item) }
            await expectFailure { _ = try await library.saveAnalysis(valid, for: item) }
            XCTAssertEqual(try Data(contentsOf: sidecar), bytes)
        }
        try FileManager.default.removeItem(at: sidecar)
        try await library.saveAnalysis(valid, for: item)
        let original = try Data(contentsOf: sidecar)
        var invalid = valid; invalid.turns[0].sampleEnd = 5
        await expectFailure { _ = try await library.saveAnalysis(invalid, for: item) }
        invalid = valid; invalid.turns.append(valid.turns[0])
        await expectFailure { _ = try await library.saveAnalysis(invalid, for: item) }
        invalid = valid; invalid.turns[0].end = 7
        await expectFailure { _ = try await library.saveAnalysis(invalid, for: item) }
        XCTAssertEqual(try Data(contentsOf: sidecar), original)
    }

    func testChangedSourceAndIdentityCannotReuseConfirmationOrOverwriteOldAnalysis() async throws {
        let root = try temporary(), item = try await recording(root)
        let library = VoiceLibrary(folder: root.appendingPathComponent("Private"))
        let person = try await library.createPerson(name: "Alex")
        let original = try analysis(item)
        try await library.saveAnalysis(original, for: item)
        try await library.confirm(turnID: "turn-1", in: item, personID: person.id)
        let sidecar = VoiceLibrary.analysisURL(for: item.url), bytes = try Data(contentsOf: VoiceLibrary.analysisURL(for: item.url))
        try generatedAudio(at: item.url, frequency: 0.17)
        await expectFailure { _ = try await library.loadAnalysis(for: item) }
        await expectFailure { _ = try await library.confirm(turnID: "turn-1", in: item, personID: person.id) }
        await expectFailure { _ = try await library.saveAnalysis(original, for: item) }
        XCTAssertEqual(try Data(contentsOf: sidecar), bytes)
        let request = try await library.analysisRequest(for: item, modelID: model)
        XCTAssertNotEqual(request.audioHash, original.audioHash)
        var changed = original; changed.audioHash = request.audioHash
        let newAnalysis = try await library.saveAnalysis(changed, for: item)
        XCTAssertNil(newAnalysis.turns[0].confirmedPersonID)
        var otherIdentity = item; otherIdentity.metadata.id = UUID().uuidString
        await expectFailure { _ = try await library.loadAnalysis(for: otherIdentity) }
    }

    func testDifferentModelOrTurnRangeDoesNotInheritHumanLabel() async throws {
        let root = try temporary(), item = try await recording(root)
        let library = VoiceLibrary(folder: root.appendingPathComponent("Private"))
        let person = try await library.createPerson(name: "Alex")
        let raw = try analysis(item)
        try await library.saveAnalysis(raw, for: item)
        try await library.confirm(turnID: "turn-1", in: item, personID: person.id)
        var changed = raw; changed.modelID = "new-model"
        var loaded = try await library.saveAnalysis(changed, for: item)
        XCTAssertNil(loaded.turns[0].confirmedPersonID)
        changed = raw; changed.turns[0].end = 4.5
        loaded = try await library.saveAnalysis(changed, for: item)
        XCTAssertNil(loaded.turns[0].confirmedPersonID)
        try await library.unconfirm(turnID: "turn-1", in: item)
        let people = try await library.profiles()
        XCTAssertTrue(people[0].examples.isEmpty)
        loaded = try await library.saveAnalysis(raw, for: item)
        XCTAssertNil(loaded.turns[0].confirmedPersonID)
    }

    func testTransactionFailureDoesNotCreateAnEnrollmentOrModifyOtherFiles() async throws {
        let root = try temporary(), item = try await recording(root)
        let blocked = root.appendingPathComponent("NotAFolder")
        let sentinel = Data("preserve this file".utf8); try sentinel.write(to: blocked)
        let library = VoiceLibrary(folder: blocked)
        await expectFailure { _ = try await library.createPerson(name: "Alex") }
        XCTAssertEqual(try Data(contentsOf: blocked), sentinel)
        let validLibrary = VoiceLibrary(folder: root.appendingPathComponent("Private"))
        try await validLibrary.saveAnalysis(analysis(item), for: item)
        await expectFailure { _ = try await validLibrary.confirm(turnID: "turn-1", in: item, personID: UUID().uuidString) }
        let people = try await validLibrary.profiles()
        XCTAssertTrue(people.isEmpty)
        let loaded = try await validLibrary.loadAnalysis(for: item)
        XCTAssertNil(loaded?.turns[0].confirmedPersonID)
    }

    func testIndependentInstancesDoNotLosePeopleAndInvalidNamesDoNotWrite() async throws {
        let root = try temporary(), folder = root.appendingPathComponent("Private")
        let first = VoiceLibrary(folder: folder), second = VoiceLibrary(folder: folder)
        async let a = first.createPerson(name: "A")
        async let b = second.createPerson(name: "B")
        _ = try await (a, b)
        let people = try await first.profiles()
        XCTAssertEqual(Set(people.map(\.name)), ["A", "B"])
        let url = folder.appendingPathComponent("voice-library.json"), bytes = try Data(contentsOf: url)
        await expectFailure { _ = try await first.createPerson(name: " \n ") }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testReusedTurnIDWithChangedAnalysisRejectsStaleConfirmationUnconfirmationAndNaming() async throws {
        let root = try temporary(), item = try await recording(root)
        let folder = root.appendingPathComponent("Private"), library = VoiceLibrary(folder: folder)
        let person = try await library.createPerson(name: "Alex")
        let original = try analysis(item)
        try await library.saveAnalysis(original, for: item)
        let expected = try await library.confirm(turnID: "turn-1", in: item, personID: person.id, expected: original)
        let store = folder.appendingPathComponent("voice-library.json"), stored = try Data(contentsOf: folder.appendingPathComponent("voice-library.json"))
        var variants: [VoiceAnalysis] = []
        var changed = original; changed.createdAt = original.createdAt.addingTimeInterval(1); variants.append(changed)
        changed = original; changed.turns[0].end = 4.5; variants.append(changed)
        changed = original; changed.turns[0].sampleStart = 1; variants.append(changed)
        changed = original; changed.turns[0].embedding = vector(0, 1); variants.append(changed)
        changed = original; changed.modelID = "another-model"; variants.append(changed)
        changed = original; changed.turns[0].speakerID = "another-anonymous-speaker"; variants.append(changed)
        for current in variants {
            try await library.saveAnalysis(current, for: item)
            let sidecar = VoiceLibrary.analysisURL(for: item.url), raw = try Data(contentsOf: VoiceLibrary.analysisURL(for: item.url))
            await expectFailure { _ = try await library.confirm(turnID: "turn-1", in: item, personID: person.id, expected: expected) }
            await expectFailure { _ = try await library.unconfirm(turnID: "turn-1", in: item, expected: expected) }
            await expectFailure { _ = try await library.name(turnID: "turn-1", in: item, newName: "Should not exist", expected: expected) }
            XCTAssertEqual(try Data(contentsOf: store), stored)
            XCTAssertEqual(try Data(contentsOf: sidecar), raw)
            let people = try await library.profiles()
            XCTAssertEqual(people.count, 1)
            XCTAssertEqual(people[0].examples.count, 1)
        }
    }

    func testAtomicNamingPersistsPersonConfirmationAndExampleAndIgnoresOverlayInSnapshot() async throws {
        let root = try temporary(), item = try await recording(root)
        let folder = root.appendingPathComponent("Private"), library = VoiceLibrary(folder: folder)
        let original = try analysis(item)
        try await library.saveAnalysis(original, for: item)
        var expected = original
        expected.turns[0].confirmedPersonID = UUID().uuidString // presentation overlay is not source identity
        let named = try await library.name(turnID: "turn-1", in: item, newName: " Alex ", expected: expected)
        let id = try XCTUnwrap(named.turns[0].confirmedPersonID)
        let restarted = VoiceLibrary(folder: folder)
        let people = try await restarted.profiles()
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0].id, id)
        XCTAssertEqual(people[0].name, "Alex")
        XCTAssertEqual(people[0].examples.count, 1)
        let restored = try await restarted.loadAnalysis(for: item)
        XCTAssertEqual(restored?.turns[0].confirmedPersonID, id)
        let cleared = try await restarted.unconfirm(turnID: "turn-1", in: item, expected: original)
        XCTAssertNil(cleared.turns[0].confirmedPersonID)
        let clearedPeople = try await restarted.profiles()
        XCTAssertTrue(clearedPeople[0].examples.isEmpty)
    }

    func testAtomicNamingDoesNotCreatePersonWhenOriginalAudioDisappears() async throws {
        let root = try temporary(), item = try await recording(root)
        let folder = root.appendingPathComponent("Private"), library = VoiceLibrary(folder: folder)
        let original = try analysis(item)
        try await library.saveAnalysis(original, for: item)
        try FileManager.default.removeItem(at: item.url)
        await expectFailure { _ = try await library.name(turnID: "turn-1", in: item, newName: "Alex", expected: original) }
        let people = try await library.profiles()
        XCTAssertTrue(people.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("voice-library.json").path))
    }
}
