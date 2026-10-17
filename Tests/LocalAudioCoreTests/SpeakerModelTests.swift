import Foundation
import XCTest
@testable import LocalAudioCore

@MainActor
final class SpeakerModelTests: XCTestCase {
    private func temporary() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAudio-speaker-model-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func manifest(replacingPath oldPath: String, with newPath: String) throws -> ModelManifest {
        let manifest = try ModelManifest.bundled(pack: .speakers)
        let files = manifest.files.map { file in
            ModelManifestFile(path: file.path == oldPath ? newPath : file.path,
                url: URL(string: "https://huggingface.co/\(manifest.repository)/resolve/\(manifest.revision)/\(file.path == oldPath ? newPath : file.path)")!,
                size: file.size, algorithm: file.algorithm, digest: file.digest)
        }
        return ModelManifest(schemaVersion: manifest.schemaVersion, id: manifest.id, repository: manifest.repository,
            revision: manifest.revision, displayName: manifest.displayName, license: manifest.license,
            licenseURL: manifest.licenseURL, attribution: manifest.attribution, modelCardURL: manifest.modelCardURL,
            totalBytes: manifest.totalBytes, files: files)
    }

    func testPinnedSpeakerManifestIsCompleteAndLimitedToCommunityAssets() throws {
        let manifest = try ModelManifest.bundled(pack: .speakers)
        XCTAssertEqual(manifest.revision, "7eab74f3463c736418d0eb10296261ae581146c9")
        XCTAssertEqual(ModelPack.speakers.modelID, "speakers-community-1@" + manifest.revision)
        XCTAssertEqual(manifest.totalBytes, 21_641_906)
        XCTAssertEqual(ModelPack.speakers.totalBytes, manifest.totalBytes)
        XCTAssertEqual(manifest.files.count, 26)
        XCTAssertEqual(manifest.files.reduce(Int64(0)) { $0 + $1.size }, manifest.totalBytes)
        XCTAssertEqual(manifest.license, "CC-BY-4.0")
        XCTAssertTrue(manifest.attribution.contains("pyannote"))
        XCTAssertTrue(manifest.attribution.contains("WeSpeaker"))
        XCTAssertTrue(manifest.attribution.contains("BUT Speech@FIT"))
        XCTAssertTrue(manifest.attribution.contains("FluidInference"))
        XCTAssertEqual(manifest.requiredBundles, ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc"])
        for name in ["README.md", "LICENSE", "NOTICE.md", "PROVENANCE.md", "provenance.json", "plda-parameters.json"] {
            XCTAssertTrue(manifest.files.contains { $0.path == name }, name)
        }
        XCTAssertTrue(manifest.files.allSatisfy { !$0.path.contains("wespeaker") && !$0.path.contains("pyannote_segmentation") })
        XCTAssertEqual(manifest.files.first { $0.path == "Embedding.mlmodelc/weights/weight.bin" }?.digest,
            "99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b")
    }

    func testManifestRejectsLegacyAndArbitraryExtraAssets() throws {
        for path in ["wespeaker_v2.mlmodelc/weights/weight.bin", "pyannote_segmentation.mlmodelc/model.mil", "Embedding.mlmodelc/unknown.bin", "arbitrary.json"] {
            let changed = try manifest(replacingPath: "Embedding.mlmodelc/weights/weight.bin", with: path)
            XCTAssertThrowsError(try changed.validate(), path)
        }
    }

    func testPackagedSpeakerHelperFindsStandardSiblingResources() throws {
        let root = try temporary()
        let contents = root.appendingPathComponent("LocalAudio.app/Contents")
        let resources = contents.appendingPathComponent("Resources/LocalAudio_LocalAudioCore.bundle")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let expected = try ModelManifest.bundled(pack: .speakers)
        try JSONEncoder().encode(expected).write(to: resources.appendingPathComponent("speakers-community-1.json"))
        let helper = contents.appendingPathComponent("Helpers/local-audio-speakers")
        var evaluatedFallback = false
        let actual = try ModelManifest.bundled(pack: .speakers, resourcesDirectory: helper.deletingLastPathComponent(),
            executableURL: helper, fallback: { evaluatedFallback = true; return nil })
        XCTAssertEqual(actual.revision, expected.revision)
        XCTAssertFalse(evaluatedFallback)
    }

    func testMissingLocalSpeakerModelsFailOfflineWithRepairInstructions() throws {
        let root = try temporary()
        XCTAssertThrowsError(try SpeakerModelCompatibility.validate(in: root)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Install or repair Speaker Models"))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private func psiJSON(_ values: [Float]) throws -> Data {
        var bytes = Data()
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        return try JSONSerialization.data(withJSONObject: ["tensors": ["psi": ["data_base64": bytes.base64EncodedString()]]])
    }

    func testPLDAParametersDecodeExplicitLittleEndianFloats() throws {
        let expected = (0..<128).map { Float($0) / 16 }
        let values = try SpeakerModelCompatibility.pldaPsi(from: psiJSON(expected))
        XCTAssertEqual(values, expected.map(Double.init))
    }

    func testPLDARejectsIncompleteInvalidAndNonfiniteData() throws {
        for values in [[Float](repeating: 1, count: 127), [Float](repeating: -1, count: 128),
                       [Float](repeating: .infinity, count: 128), [Float](repeating: .nan, count: 128)] {
            XCTAssertThrowsError(try SpeakerModelCompatibility.pldaPsi(from: psiJSON(values)))
        }
        XCTAssertThrowsError(try SpeakerModelCompatibility.pldaPsi(from: Data("{}".utf8)))
        XCTAssertThrowsError(try SpeakerModelCompatibility.pldaPsi(from: Data("{\"tensors\":{\"psi\":{\"data_base64\":\"!\"}}}".utf8)))
    }

    func testRepresentativeClipIsCenteredBoundedAndExcludesOtherSpeakers() throws {
        let turn = VoiceTurn(id: "a", start: 0, end: 12, speakerID: "S1")
        let centered = try XCTUnwrap(SpeakerClipPolicy.representativeSpan(for: turn, among: [turn]))
        XCTAssertEqual(centered.start, 3.5, accuracy: 1e-9)
        XCTAssertEqual(centered.end, 8.5, accuracy: 1e-9)
        let overlap = VoiceTurn(id: "b", start: 0, end: 5, speakerID: "S2")
        let clean = try XCTUnwrap(SpeakerClipPolicy.representativeSpan(for: turn, among: [turn, overlap]))
        XCTAssertGreaterThanOrEqual(clean.start, overlap.end + 0.15)
        XCTAssertLessThanOrEqual(clean.end, turn.end - 0.15)
        XCTAssertEqual(clean.end - clean.start, 5, accuracy: 1e-9)
    }

    func testShortOverlappingAndInvalidTurnsHaveNoEnrollmentClip() {
        let short = VoiceTurn(id: "s", start: 0, end: 2.2, speakerID: "S1")
        XCTAssertNil(SpeakerClipPolicy.representativeSpan(for: short, among: [short]))
        let turn = VoiceTurn(id: "a", start: 0, end: 5, speakerID: "S1")
        let overlap = VoiceTurn(id: "b", start: 0.8, end: 4.2, speakerID: "S2")
        XCTAssertNil(SpeakerClipPolicy.representativeSpan(for: turn, among: [turn, overlap]))
        for interval in [(Double.nan, 5.0), (0.0, Double.infinity), (-1.0, 5.0), (5.0, 4.0)] {
            let invalid = VoiceTurn(id: "i", start: interval.0, end: interval.1, speakerID: "S1")
            XCTAssertNil(SpeakerClipPolicy.representativeSpan(for: invalid, among: []))
        }
    }

    func testSilenceClippingNonfiniteAndTooShortSignalAreRejected() {
        XCTAssertTrue(SpeakerClipPolicy.hasUsableSignal([Float](repeating: 0.02, count: 32_000)))
        XCTAssertFalse(SpeakerClipPolicy.hasUsableSignal([Float](repeating: 0, count: 32_000)))
        XCTAssertFalse(SpeakerClipPolicy.hasUsableSignal([Float](repeating: 1, count: 32_000)))
        XCTAssertFalse(SpeakerClipPolicy.hasUsableSignal([Float](repeating: .nan, count: 32_000)))
        XCTAssertFalse(SpeakerClipPolicy.hasUsableSignal([Float](repeating: 0.02, count: 31_999)))
    }

    func testEmbeddingNormalizationRejectsUnusableDimensionsAndValues() throws {
        let normalized = try XCTUnwrap(SpeakerClipPolicy.normalizedEmbedding([Float](repeating: 2, count: 256)))
        XCTAssertEqual(normalized.count, 256)
        XCTAssertEqual(normalized.reduce(0.0) { $0 + Double($1 * $1) }, 1, accuracy: 1e-6)
        XCTAssertNil(SpeakerClipPolicy.normalizedEmbedding([Float](repeating: 1, count: 255)))
        XCTAssertNil(SpeakerClipPolicy.normalizedEmbedding([Float](repeating: 0, count: 256)))
        XCTAssertNil(SpeakerClipPolicy.normalizedEmbedding([Float](repeating: .infinity, count: 256)))
    }
}
