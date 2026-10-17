import Foundation

public enum ModelPack: String, Codable, CaseIterable, Sendable {
    case transcription = "parakeet-v2"
    case speakers = "speakers-community-1"

    public var modelID: String { rawValue + "@" + revision }
    public var displayName: String {
        switch self {
        case .transcription: return "Parakeet TDT v2 (English)"
        case .speakers: return "Local speaker analysis (Community-1)"
        }
    }
    public var license: String { "CC-BY-4.0" }
    public var licenseURL: URL { URL(string: "https://creativecommons.org/licenses/by/4.0/")! }
    public var attribution: String {
        switch self {
        case .transcription:
            return "Parakeet TDT 0.6B v2 by NVIDIA. Core ML conversion and Swift integration by FluidInference. LocalAudio downloads the selected compiled assets without modification."
        case .speakers:
            return "Community-1 models by pyannote, speaker embeddings from WeSpeaker, PLDA by BUT Speech@FIT, converted to Core ML by FluidInference. These are modified Core ML conversions; LocalAudio downloads the selected files unchanged. Scope: only the selected Community-1 assets, not legacy models."
        }
    }
    public var totalBytes: Int64 { self == .transcription ? 464_414_912 : 21_641_906 }
    public var modelCardURL: URL { URL(string: "https://huggingface.co/\(repository)/blob/\(revision)/README.md")! }
    public var noticeURL: URL { URL(string: "https://huggingface.co/\(repository)/blob/\(revision)/\(self == .speakers ? "NOTICE.md" : "README.md")")! }

    var revision: String {
        self == .transcription ? "ee09c569f73759e6d44c9bd16766f477b2b36d39" : "7eab74f3463c736418d0eb10296261ae581146c9"
    }
    var repository: String {
        self == .transcription ? "FluidInference/parakeet-tdt-0.6b-v2-coreml" : "FluidInference/speaker-diarization-coreml"
    }
    var requiredBundles: [String] {
        switch self {
        case .transcription: return ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc"]
        case .speakers: return ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc"]
        }
    }
    var parameterFile: String { self == .transcription ? "parakeet_vocab.json" : "plda-parameters.json" }
    var attributionFiles: Set<String> {
        self == .transcription ? ["README.md"] : ["README.md", "LICENSE", "NOTICE.md", "PROVENANCE.md", "provenance.json"]
    }
    var setupPrompt: String {
        self == .transcription ? "Download the English model or choose an existing local model folder."
            : "Install optional speaker models or choose an existing supported speaker-model folder."
    }
    var readyText: String {
        self == .transcription ? "English model loaded and ready." : "Speaker models loaded and ready."
    }
}
