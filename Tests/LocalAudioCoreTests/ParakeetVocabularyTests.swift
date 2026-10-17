import XCTest
@testable import LocalAudioCore

final class ParakeetVocabularyTests: XCTestCase {
    func testPublishedPackShapeAllowsAppendedTokensAboveBlank() throws {
        let fixture = Dictionary(uniqueKeysWithValues: (0...1030).map { (String($0), "token\($0)") })
        let decoded = try ParakeetVocabulary.decodeV2(JSONSerialization.data(withJSONObject: fixture))
        XCTAssertEqual(decoded.count, 1031)
        XCTAssertEqual(decoded[1030], "token1030")
    }
    func testMissingBaseTokenAndMalformedIdentifiersFail() throws {
        var fixture = Dictionary(uniqueKeysWithValues: (0..<1024).map { (String($0), "token") })
        fixture["32"] = nil
        XCTAssertThrowsError(try ParakeetVocabulary.decodeV2(JSONSerialization.data(withJSONObject: fixture)))
        fixture["32"] = "token"; fixture["01"] = "ambiguous"
        XCTAssertThrowsError(try ParakeetVocabulary.decodeV2(JSONSerialization.data(withJSONObject: fixture)))
        XCTAssertThrowsError(try ParakeetVocabulary.decodeV2(Data("{}".utf8)))
    }
}
