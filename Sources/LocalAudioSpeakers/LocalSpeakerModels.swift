import Foundation
@preconcurrency import CoreML
import FluidAudio
import LocalAudioCore

enum LocalSpeakerModels {
    static func load(_ folder: URL) throws -> OfflineDiarizerModels {
        try SpeakerModelCompatibility.validate(in: folder)
        let start = Date()
        func model(_ name: String, cpu: Bool = false) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = cpu ? .cpuOnly : .all
            return try MLModel(contentsOf: folder.appendingPathComponent(name + ".mlmodelc"), configuration: configuration)
        }
        let psi = try SpeakerModelCompatibility.pldaPsi(from: Data(contentsOf: folder.appendingPathComponent("plda-parameters.json")))
        return try OfflineDiarizerModels(segmentationModel: model("Segmentation"), fbankModel: model("FBank", cpu: true),
            embeddingModel: model("Embedding"), pldaRhoModel: model("PldaRho"), pldaPsi: psi,
            compilationDuration: Date().timeIntervalSince(start))
    }
}
