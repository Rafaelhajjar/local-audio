import Foundation
import XCTest
import LocalAudioCore
@testable import LocalAudioSpeakers

final class HelperSafetyTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAudio-helper-safety-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func request(at root: URL, recipe: String = VoiceEmbeddingRecipe.legacy) throws -> URL {
        let analysis = VoiceAnalysis(recordingID: "fixture", audioHash: String(repeating: "a", count: 64),
            modelID: ModelPack.speakers.modelID, turns: [], recipeID: recipe)
        let request = VoiceEmbeddingRefreshRequest(analysis: analysis, audioURL: root.appendingPathComponent("fixture.caf"))
        let url = root.appendingPathComponent("request.json")
        try PrivateJSON.write(request, to: url)
        return url
    }
    func testUnsupportedRecipeRejectedBeforeAudioOrModelsAreOpened() throws {
        let root = try temporary(), requestURL = try request(at: root, recipe: "unsupported-recipe")
        let output = root.appendingPathComponent("new.json")
        XCTAssertThrowsError(try RefreshTurnEmbeddings.run(requestURL: requestURL, modelsURL: root.appendingPathComponent("no-models"), outputURL: output)) { error in
            XCTAssertTrue(error.localizedDescription.contains("supported saved analysis"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testRefreshOutputGuardsPrecedeAnyModelOrAudioInference() throws {
        let root = try temporary(), requestURL = try request(at: root)
        let models = root.appendingPathComponent("models")
        let original = try Data(contentsOf: requestURL)
        for output in [requestURL, root.appendingPathComponent("fixture.caf"), models.appendingPathComponent("result.json")] {
            XCTAssertThrowsError(try RefreshTurnEmbeddings.run(requestURL: requestURL, modelsURL: models, outputURL: output))
        }
        XCTAssertEqual(try Data(contentsOf: requestURL), original)
        let existing = root.appendingPathComponent("existing.json")
        try Data("preserved".utf8).write(to: existing)
        XCTAssertThrowsError(try RefreshTurnEmbeddings.run(requestURL: requestURL, modelsURL: models, outputURL: existing))
        XCTAssertEqual(try Data(contentsOf: existing), Data("preserved".utf8))
    }
    func testExclusivePublicationPreservesExistingFile() throws {
        let root = try temporary(), output = root.appendingPathComponent("result.json")
        try Speakers.publish(["fixture": "first"], to: output)
        let original = try Data(contentsOf: output)
        XCTAssertThrowsError(try Speakers.publish(["fixture": "second"], to: output))
        XCTAssertEqual(try Data(contentsOf: output), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["result.json"])
    }
}
