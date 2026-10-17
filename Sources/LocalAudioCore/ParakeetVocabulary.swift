import Foundation

public enum ParakeetVocabulary {
    /// The published v2 pack includes appended custom-vocabulary entries above
    /// the base model's blank ID. They must not invalidate its 1024 base tokens.
    public static func decodeV2(_ data: Data) throws -> [Int: String] {
        let raw = try JSONSerialization.jsonObject(with: data)
        var vocabulary: [Int: String] = [:]
        if let dictionary = raw as? [String: String] {
            for (key, value) in dictionary {
                guard let id = Int(key), id >= 0, String(id) == key else {
                    throw LocalAudioError.message("The model vocabulary contains an invalid token ID.")
                }
                vocabulary[id] = value
            }
        } else if let array = raw as? [String] {
            vocabulary = Dictionary(uniqueKeysWithValues: array.enumerated().map { ($0.offset, $0.element) })
        }
        guard (0..<1024).allSatisfy({ vocabulary[$0] != nil }) else {
            throw LocalAudioError.message("The vocabulary is incomplete. Repair the English model in Settings.")
        }
        return vocabulary
    }
}
