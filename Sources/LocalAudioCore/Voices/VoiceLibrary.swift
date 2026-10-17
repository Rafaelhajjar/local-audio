import Foundation
import Darwin

/// Human identity decisions live in one private transaction. Helper sidecars
/// contain anonymous analysis only and can never enroll or assign a person.
public actor VoiceLibrary {
    public let folder: URL
    private var storeURL: URL { folder.appendingPathComponent("voice-library.json") }

    public init(folder: URL) { self.folder = folder.standardizedFileURL }

    public static func analysisURL(for audio: URL) -> URL { audio.appendingPathExtension("voices.json") }

    public func profiles() throws -> [VoiceProfile] { try readState().profiles }

    @discardableResult
    public func createPerson(name: String) throws -> VoiceProfile {
        let person = VoiceProfile(name: try cleanName(name))
        return try transaction { state in state.profiles.append(person); return person }
    }

    @discardableResult
    public func renamePerson(id: String, name: String) throws -> VoiceProfile {
        let name = try cleanName(name)
        return try transaction { state in
            guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { throw failure("This person no longer exists.") }
            state.profiles[index].name = name
            return state.profiles[index]
        }
    }

    public func deletePerson(id: String) throws {
        try transaction { state in
            guard state.profiles.contains(where: { $0.id == id }) else { throw failure("This person no longer exists.") }
            state.profiles.removeAll { $0.id == id }
            state.confirmations.removeAll { $0.personID == id }
        }
    }

    public func analysisRequest(for recording: AudioRecording, modelID: String) throws -> VoiceAnalysisRequest {
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure("Choose a speaker model first.") }
        return VoiceAnalysisRequest(recordingID: recording.id, audioURL: recording.url,
                                    audioHash: try stableHash(recording.url), modelID: modelID)
    }

    public func loadAnalysis(for recording: AudioRecording) throws -> VoiceAnalysis? {
        let state = try readState()
        guard let analysis = try currentAnalysis(for: recording) else { return nil }
        return overlay(analysis, state: state)
    }

    @discardableResult
    public func saveAnalysis(_ analysis: VoiceAnalysis, for recording: AudioRecording) throws -> VoiceAnalysis {
        // Fail closed if either existing document belongs to a newer app or is
        // corrupt. Never overwrite the only copy to recover from a read error.
        let state = try readState()
        let destination = Self.analysisURL(for: recording.url)
        if FileManager.default.fileExists(atPath: destination.path) { _ = try decodeAnalysis(at: destination) }
        let anonymous = try validated(analysis, duration: recording.duration)
        try requireSource(anonymous, recording: recording)
        try atomicWrite(anonymous, to: destination)
        return overlay(anonymous, state: state)
    }

    @discardableResult
    public func confirm(turnID: String, in recording: AudioRecording, personID: String,
                        expected: VoiceAnalysis? = nil) throws -> VoiceAnalysis {
        return try transaction { state in
            let (analysis, turn) = try confirmationTarget(turnID: turnID, recording: recording, expected: expected)
            try applyConfirmation(turn: turn, analysis: analysis, personID: personID, state: &state)
            return overlay(analysis, state: state)
        }
    }

    /// Creating a person through a turn's naming action is one transaction with
    /// the confirmation. A stale sheet or unavailable source leaves no person.
    @discardableResult
    public func name(turnID: String, in recording: AudioRecording, newName: String,
                     expected: VoiceAnalysis? = nil) throws -> VoiceAnalysis {
        let name = try cleanName(newName)
        return try transaction { state in
            let (analysis, turn) = try confirmationTarget(turnID: turnID, recording: recording, expected: expected)
            let person = VoiceProfile(name: name)
            state.profiles.append(person)
            try applyConfirmation(turn: turn, analysis: analysis, personID: person.id, state: &state)
            return overlay(analysis, state: state)
        }
    }

    @discardableResult
    public func unconfirm(turnID: String, in recording: AudioRecording,
                          expected: VoiceAnalysis? = nil) throws -> VoiceAnalysis {
        return try transaction { state in
            let (analysis, _) = try confirmationTarget(turnID: turnID, recording: recording, expected: expected)
            revoke(turnID: turnID, recordingID: recording.id, state: &state)
            return overlay(analysis, state: state)
        }
    }

    private func confirmationTarget(turnID: String, recording: AudioRecording,
                                    expected: VoiceAnalysis?) throws -> (VoiceAnalysis, VoiceTurn) {
        guard let analysis = try currentAnalysis(for: recording),
              let turn = analysis.turns.first(where: { $0.id == turnID }) else {
            throw failure("Analyze this recording again before changing its voice label.")
        }
        if let expected {
            guard expected.version == analysis.version, expected.recordingID == analysis.recordingID,
                  expected.audioHash == analysis.audioHash, expected.modelID == analysis.modelID,
                  expected.createdAt == analysis.createdAt,
                  let old = expected.turns.first(where: { $0.id == turnID }),
                  old.start == turn.start, old.end == turn.end, old.speakerID == turn.speakerID,
                  old.sampleStart == turn.sampleStart, old.sampleEnd == turn.sampleEnd,
                  old.embedding == turn.embedding else {
                throw failure("This voice analysis changed while you were naming it. Listen to the current turn and confirm again.")
            }
        }
        return (analysis, turn)
    }

    private func applyConfirmation(turn: VoiceTurn, analysis: VoiceAnalysis, personID: String, state: inout State) throws {
        guard let person = state.profiles.firstIndex(where: { $0.id == personID }) else { throw failure("This person no longer exists.") }
        revoke(turnID: turn.id, recordingID: analysis.recordingID, state: &state)
        let now = Date()
        var exampleID: String?
        if let start = turn.sampleStart, let end = turn.sampleEnd,
           end - start >= 2, end - start <= 5.000_001,
           let embedding = VoiceMatcher.normalized(turn.embedding) {
            let example = VoiceExample(recordingID: analysis.recordingID, audioHash: analysis.audioHash,
                                       turnID: turn.id, modelID: analysis.modelID, start: start, end: end,
                                       embedding: embedding, confirmedAt: now)
            state.profiles[person].examples.append(example)
            exampleID = example.id
        }
        state.confirmations.append(Confirmation(recordingID: analysis.recordingID, audioHash: analysis.audioHash,
            modelID: analysis.modelID, turnID: turn.id, start: turn.start, end: turn.end,
            personID: personID, confirmedAt: now, exampleID: exampleID))
    }

    private struct State: Codable {
        var version = 1
        var profiles: [VoiceProfile] = []
        var confirmations: [Confirmation] = []
    }
    private struct Confirmation: Codable {
        let recordingID: String
        let audioHash: String
        let modelID: String
        let turnID: String
        let start: Double
        let end: Double
        let personID: String
        let confirmedAt: Date
        let exampleID: String?
    }
    private struct Version: Decodable { let version: Int }

    private func readState() throws -> State {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return State() }
        do {
            let data = try Data(contentsOf: storeURL)
            guard try JSONDecoder().decode(Version.self, from: data).version == 1 else {
                throw failure("The voice library needs a newer app. Its data has been preserved.")
            }
            let state = try JSONDecoder().decode(State.self, from: data)
            try validateState(state)
            return state
        } catch {
            throw failure("Cannot read the private voice library; its data has been preserved. " + error.localizedDescription)
        }
    }

    private func transaction<T>(_ change: (inout State) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Also serialize independent VoiceLibrary instances using this folder.
        let lockURL = folder.appendingPathComponent(".voice-library.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw failure("Cannot lock the private voice library.") }
        defer { _ = Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw failure("Cannot lock the private voice library.") }
        defer { _ = flock(descriptor, LOCK_UN) }
        var state = try readState()
        let result = try change(&state)
        try validateState(state)
        try atomicWrite(state, to: storeURL)
        return result
    }

    private func revoke(turnID: String, recordingID: String, state: inout State) {
        state.confirmations.removeAll { $0.recordingID == recordingID && $0.turnID == turnID }
        for index in state.profiles.indices {
            state.profiles[index].examples.removeAll { $0.recordingID == recordingID && $0.turnID == turnID }
        }
    }

    private func overlay(_ anonymous: VoiceAnalysis, state: State) -> VoiceAnalysis {
        var analysis = anonymous
        for index in analysis.turns.indices {
            let turn = analysis.turns[index]
            analysis.turns[index].confirmedPersonID = state.confirmations.first {
                $0.recordingID == analysis.recordingID && $0.audioHash == analysis.audioHash &&
                $0.modelID == analysis.modelID && $0.turnID == turn.id && $0.start == turn.start && $0.end == turn.end
            }?.personID
        }
        return analysis
    }

    private func currentAnalysis(for recording: AudioRecording) throws -> VoiceAnalysis? {
        let url = Self.analysisURL(for: recording.url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let analysis = try validated(decodeAnalysis(at: url), duration: recording.duration)
        try requireSource(analysis, recording: recording)
        return analysis
    }

    private func decodeAnalysis(at url: URL) throws -> VoiceAnalysis {
        do {
            let data = try Data(contentsOf: url)
            guard try JSONDecoder().decode(Version.self, from: data).version == 1 else {
                throw failure("This voice analysis needs a newer app. Its data has been preserved.")
            }
            return try validated(JSONDecoder().decode(VoiceAnalysis.self, from: data), duration: nil)
        } catch { throw failure("Cannot read voice analysis; its data has been preserved. " + error.localizedDescription) }
    }

    private func validated(_ input: VoiceAnalysis, duration: Double?) throws -> VoiceAnalysis {
        guard input.version == 1, !input.recordingID.isEmpty, validHash(input.audioHash),
              !input.modelID.isEmpty, input.createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw failure("Invalid or unsupported voice analysis. Analyze this audio again.")
        }
        var ids = Set<String>()
        var result = input
        for index in result.turns.indices {
            let turn = result.turns[index]
            guard !turn.id.isEmpty, ids.insert(turn.id).inserted, !turn.speakerID.isEmpty,
                  validRange(turn.start, turn.end), duration.map({ turn.end <= $0 + 0.001 }) ?? true else {
                throw failure("Voice analysis contains an invalid or duplicate turn.")
            }
            switch (turn.sampleStart, turn.sampleEnd) {
            case (nil, nil): break
            case let (.some(start), .some(end)):
                guard validRange(start, end), start >= turn.start, end <= turn.end else {
                    throw failure("A voice example falls outside its speaker turn.")
                }
            default: throw failure("A voice example has incomplete timing.")
            }
            result.turns[index].confirmedPersonID = nil
        }
        return result
    }

    private func requireSource(_ analysis: VoiceAnalysis, recording: AudioRecording) throws {
        guard analysis.recordingID == recording.id, analysis.audioHash == (try stableHash(recording.url)) else {
            throw failure("The audio or its recording identity changed. Analyze the current file again before confirming voices.")
        }
    }

    private func stableHash(_ url: URL) throws -> String {
        let before = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard url.isFileURL, before.isRegularFile == true else { throw failure("The original audio file is unavailable.") }
        let hash = try RecordingLibrary.hash(url)
        let after = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else {
            throw failure("The audio changed while it was being checked. Wait for it to finish saving.")
        }
        return hash
    }

    private func validateState(_ state: State) throws {
        var people = Set<String>(), examples = Set<String>(), confirmedTurns = Set<String>()
        var byExample: [String: (String, VoiceExample)] = [:]
        for profile in state.profiles {
            guard UUID(uuidString: profile.id) != nil, people.insert(profile.id).inserted,
                  !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  profile.createdAt.timeIntervalSinceReferenceDate.isFinite else { throw failure("Invalid person in the voice library.") }
            for example in profile.examples {
                guard !example.id.isEmpty, examples.insert(example.id).inserted, !example.recordingID.isEmpty,
                      validHash(example.audioHash), !example.turnID.isEmpty, !example.modelID.isEmpty,
                      validRange(example.start, example.end), example.end - example.start >= 2,
                      example.end - example.start <= 5.000_001, example.confirmedAt.timeIntervalSinceReferenceDate.isFinite,
                      let normalized = VoiceMatcher.normalized(example.embedding),
                      zip(normalized, example.embedding).allSatisfy({ abs($0 - $1) < 0.0001 }) else {
                    throw failure("Invalid confirmed example in the voice library.")
                }
                byExample[example.id] = (profile.id, example)
            }
        }
        for confirmation in state.confirmations {
            let key = confirmation.recordingID + "\u{0}" + confirmation.turnID
            guard !confirmation.recordingID.isEmpty, !confirmation.turnID.isEmpty, !confirmation.modelID.isEmpty,
                  validHash(confirmation.audioHash), validRange(confirmation.start, confirmation.end),
                  people.contains(confirmation.personID), confirmedTurns.insert(key).inserted,
                  confirmation.confirmedAt.timeIntervalSinceReferenceDate.isFinite else { throw failure("Invalid voice confirmation.") }
            if let id = confirmation.exampleID {
                guard let (person, example) = byExample.removeValue(forKey: id), person == confirmation.personID,
                      example.recordingID == confirmation.recordingID, example.audioHash == confirmation.audioHash,
                      example.turnID == confirmation.turnID, example.modelID == confirmation.modelID,
                      example.start >= confirmation.start, example.end <= confirmation.end,
                      example.confirmedAt == confirmation.confirmedAt else { throw failure("A voice example has no matching human confirmation.") }
            }
        }
        guard byExample.isEmpty else { throw failure("A voice example has no human confirmation.") }
    }

    private func atomicWrite<T: Encodable>(_ value: T, to destination: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".voice-write-" + UUID().uuidString)
        let descriptor = Darwin.open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw failure("Cannot write voice data in " + parent.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: staging) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(staging.path, destination.path) == 0 else {
            throw failure("Cannot save voice data. The existing file has been preserved: " + destination.path)
        }
    }

    private func cleanName(_ name: String) throws -> String {
        let result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw failure("Enter a name for this person.") }
        return result
    }
    private func validHash(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func validRange(_ start: Double, _ end: Double) -> Bool {
        start.isFinite && end.isFinite && start >= 0 && end > start
    }
    private func failure(_ message: String) -> LocalAudioError { .message(message) }
}
