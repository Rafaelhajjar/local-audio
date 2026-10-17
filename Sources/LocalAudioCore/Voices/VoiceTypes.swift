import Foundation

public struct VoiceAnalysisRequest: Codable, Equatable, Sendable {
    public var recordingID: String
    public var audioURL: URL
    public var audioHash: String
    public var modelID: String
    public init(recordingID: String, audioURL: URL, audioHash: String, modelID: String) {
        self.recordingID = recordingID; self.audioURL = audioURL
        self.audioHash = audioHash; self.modelID = modelID
    }
}

public struct VoiceTurn: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var start: Double
    public var end: Double
    public var speakerID: String
    public var embedding: [Float]?
    public var sampleStart: Double?
    public var sampleEnd: Double?
    /// A presentation overlay from the private human-confirmation store. Raw
    /// helper output is never trusted to set this field or enroll an example.
    public var confirmedPersonID: String?
    public init(id: String, start: Double, end: Double, speakerID: String,
                embedding: [Float]? = nil, sampleStart: Double? = nil, sampleEnd: Double? = nil,
                confirmedPersonID: String? = nil) {
        self.id = id; self.start = start; self.end = end; self.speakerID = speakerID
        self.embedding = embedding; self.sampleStart = sampleStart; self.sampleEnd = sampleEnd
        self.confirmedPersonID = confirmedPersonID
    }
}

public struct VoiceAnalysis: Codable, Equatable, Sendable {
    public var version: Int
    public var recordingID: String
    public var audioHash: String
    public var modelID: String
    public var turns: [VoiceTurn]
    public var createdAt: Date
    public init(version: Int = 1, recordingID: String, audioHash: String, modelID: String,
                turns: [VoiceTurn], createdAt: Date = Date()) {
        self.version = version; self.recordingID = recordingID; self.audioHash = audioHash
        self.modelID = modelID; self.turns = turns; self.createdAt = createdAt
    }
}

public struct VoiceExample: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let recordingID: String
    public let audioHash: String
    public let turnID: String
    public let modelID: String
    public let start: Double
    public let end: Double
    public let embedding: [Float]
    public let confirmedAt: Date
    public init(id: String = UUID().uuidString, recordingID: String, audioHash: String, turnID: String,
                modelID: String, start: Double, end: Double, embedding: [Float], confirmedAt: Date = Date()) {
        self.id = id; self.recordingID = recordingID; self.audioHash = audioHash; self.turnID = turnID
        self.modelID = modelID; self.start = start; self.end = end
        self.embedding = embedding; self.confirmedAt = confirmedAt
    }
}

public struct VoiceProfile: Codable, Equatable, Identifiable, Sendable {
    /// UUID represented as a string, matching VoiceTurn.confirmedPersonID.
    public let id: String
    public var name: String
    public let createdAt: Date
    public var examples: [VoiceExample]
    public init(id: String = UUID().uuidString, name: String, createdAt: Date = Date(), examples: [VoiceExample] = []) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.examples = examples
    }
}

public struct VoiceCandidate: Equatable, Sendable {
    public let personID: String
    public let name: String
    /// Cosine similarity of stored, explicitly confirmed examples. This is not
    /// a calibrated confidence or a probability that the identity is correct.
    public let similarity: Double
    public let margin: Double
    public let exampleCount: Int
    public init(personID: String, name: String, similarity: Double, margin: Double, exampleCount: Int) {
        self.personID = personID; self.name = name; self.similarity = similarity
        self.margin = margin; self.exampleCount = exampleCount
    }
}
