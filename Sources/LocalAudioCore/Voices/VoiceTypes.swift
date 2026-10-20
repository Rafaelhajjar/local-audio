import Foundation

/// A vector's extraction recipe is separate from the model's pinned weights.
/// Vectors from these recipes must never be averaged or compared together.
public enum VoiceEmbeddingRecipe {
    public static let legacy = "localaudio-clip-v1-native-crop-resample16k-zero-tail10s-mask589-l2"
    public static let current = "localaudio-turn-v2-periodic10s-originalmask589-center-start-end-dominantsolo-l2"
    public static func isSupported(_ id: String) -> Bool { id == legacy || id == current }
}

public struct VoiceSampleSpan: Codable, Equatable, Sendable {
    public let start: Double
    public let end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

public struct VoiceAnalysisRequest: Codable, Equatable, Sendable {
    public var recordingID: String
    public var audioURL: URL
    public var audioHash: String
    public var modelID: String
    public var recipeID: String
    public init(recordingID: String, audioURL: URL, audioHash: String, modelID: String,
                recipeID: String = VoiceEmbeddingRecipe.legacy) {
        self.recordingID = recordingID; self.audioURL = audioURL
        self.audioHash = audioHash; self.modelID = modelID; self.recipeID = recipeID
    }
    private enum CodingKeys: String, CodingKey { case recordingID, audioURL, audioHash, modelID, recipeID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(recordingID: try c.decode(String.self, forKey: .recordingID),
                  audioURL: try c.decode(URL.self, forKey: .audioURL), audioHash: try c.decode(String.self, forKey: .audioHash),
                  modelID: try c.decode(String.self, forKey: .modelID),
                  recipeID: try c.decodeIfPresent(String.self, forKey: .recipeID) ?? VoiceEmbeddingRecipe.legacy)
    }
}

public struct VoiceEmbeddingRefreshRequest: Codable, Equatable, Sendable {
    public var analysis: VoiceAnalysis
    public var audioURL: URL
    public init(analysis: VoiceAnalysis, audioURL: URL) { self.analysis = analysis; self.audioURL = audioURL }
}

public struct VoiceTurn: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var start: Double
    public var end: Double
    public var speakerID: String
    public var embedding: [Float]?
    public var sampleStart: Double?
    public var sampleEnd: Double?
    /// Actual contributing clips; sampleStart/sampleEnd is only the preview.
    public var embeddingSpans: [VoiceSampleSpan]?
    /// A presentation overlay from the private human-confirmation store. Raw
    /// helper output is never trusted to set this field or enroll an example.
    public var confirmedPersonID: String?
    public init(id: String, start: Double, end: Double, speakerID: String,
                embedding: [Float]? = nil, sampleStart: Double? = nil, sampleEnd: Double? = nil,
                confirmedPersonID: String? = nil, embeddingSpans: [VoiceSampleSpan]? = nil) {
        self.id = id; self.start = start; self.end = end; self.speakerID = speakerID
        self.embedding = embedding; self.sampleStart = sampleStart; self.sampleEnd = sampleEnd
        self.confirmedPersonID = confirmedPersonID; self.embeddingSpans = embeddingSpans
    }
}

public struct VoiceAnalysis: Codable, Equatable, Sendable {
    public var version: Int
    public var recordingID: String
    public var audioHash: String
    public var modelID: String
    public var recipeID: String
    public var turns: [VoiceTurn]
    public var createdAt: Date
    public init(version: Int? = nil, recordingID: String, audioHash: String, modelID: String,
                turns: [VoiceTurn], createdAt: Date = Date(), recipeID: String = VoiceEmbeddingRecipe.legacy) {
        self.version = version ?? (recipeID == VoiceEmbeddingRecipe.legacy ? 1 : 2)
        self.recordingID = recordingID; self.audioHash = audioHash
        self.modelID = modelID; self.turns = turns; self.createdAt = createdAt; self.recipeID = recipeID
    }
    private enum CodingKeys: String, CodingKey { case version, recordingID, audioHash, modelID, turns, createdAt, recipeID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(version: try c.decode(Int.self, forKey: .version),
                  recordingID: try c.decode(String.self, forKey: .recordingID), audioHash: try c.decode(String.self, forKey: .audioHash),
                  modelID: try c.decode(String.self, forKey: .modelID), turns: try c.decode([VoiceTurn].self, forKey: .turns),
                  createdAt: try c.decode(Date.self, forKey: .createdAt),
                  recipeID: try c.decodeIfPresent(String.self, forKey: .recipeID) ?? VoiceEmbeddingRecipe.legacy)
    }
}

public struct VoiceExample: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let recordingID: String
    public let audioHash: String
    public let turnID: String
    public let modelID: String
    public let recipeID: String
    public let start: Double
    public let end: Double
    public let embedding: [Float]
    public let confirmedAt: Date
    public let embeddingSpans: [VoiceSampleSpan]?
    /// A failed refresh keeps its human enrollment provenance for a later retry.
    public let isAvailableForMatching: Bool
    public init(id: String = UUID().uuidString, recordingID: String, audioHash: String, turnID: String,
                modelID: String, start: Double, end: Double, embedding: [Float], confirmedAt: Date = Date(),
                recipeID: String = VoiceEmbeddingRecipe.legacy, embeddingSpans: [VoiceSampleSpan]? = nil,
                isAvailableForMatching: Bool = true) {
        self.id = id; self.recordingID = recordingID; self.audioHash = audioHash; self.turnID = turnID
        self.modelID = modelID; self.start = start; self.end = end
        self.embedding = embedding; self.confirmedAt = confirmedAt; self.recipeID = recipeID; self.embeddingSpans = embeddingSpans
        self.isAvailableForMatching = isAvailableForMatching
    }
    private enum CodingKeys: String, CodingKey { case id, recordingID, audioHash, turnID, modelID, start, end, embedding, confirmedAt, recipeID, embeddingSpans, isAvailableForMatching }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), recordingID: try c.decode(String.self, forKey: .recordingID),
                  audioHash: try c.decode(String.self, forKey: .audioHash), turnID: try c.decode(String.self, forKey: .turnID),
                  modelID: try c.decode(String.self, forKey: .modelID), start: try c.decode(Double.self, forKey: .start),
                  end: try c.decode(Double.self, forKey: .end), embedding: try c.decode([Float].self, forKey: .embedding),
                  confirmedAt: try c.decode(Date.self, forKey: .confirmedAt),
                  recipeID: try c.decodeIfPresent(String.self, forKey: .recipeID) ?? VoiceEmbeddingRecipe.legacy,
                  embeddingSpans: try c.decodeIfPresent([VoiceSampleSpan].self, forKey: .embeddingSpans),
                  isAvailableForMatching: try c.decodeIfPresent(Bool.self, forKey: .isAvailableForMatching) ?? true)
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
