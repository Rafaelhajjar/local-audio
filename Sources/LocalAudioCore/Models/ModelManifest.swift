import Foundation
import CryptoKit

struct ModelManifest: Codable, Sendable {
    let schemaVersion: Int
    let id: String
    let repository: String
    let revision: String
    let displayName: String
    let license: String
    let licenseURL: URL
    let attribution: String
    let modelCardURL: URL
    let totalBytes: Int64
    let files: [ModelManifestFile]

    static func bundled(resourcesDirectory: URL? = Bundle.main.resourceURL,
                        executableURL: URL? = Bundle.main.executableURL,
                        fallback: () -> URL? = { Bundle.module.url(forResource: "parakeet-v2", withExtension: "json") }) throws -> Self {
        // SwiftPM's generated accessor may embed an absolute development path
        // or look beside the app. Resolve the standard packaged resource first;
        // do not evaluate Bundle.module until that location has been checked.
        var candidates = resourcesDirectory.map {
            [$0.appendingPathComponent("LocalAudio_LocalAudioCore.bundle", isDirectory: true)]
        } ?? []
        if let executableURL, executableURL.lastPathComponent == "local-audio-transcriber",
           executableURL.deletingLastPathComponent().lastPathComponent == "Helpers" {
            let contents = executableURL.deletingLastPathComponent().deletingLastPathComponent()
            candidates.append(contents.appendingPathComponent("Resources/LocalAudio_LocalAudioCore.bundle", isDirectory: true))
        }
        var packagedURL: URL?
        for candidate in candidates {
            let direct = candidate.appendingPathComponent("parakeet-v2.json")
            if FileManager.default.isReadableFile(atPath: direct.path) {
                packagedURL = direct
                break
            }
            if let bundle = Bundle(url: candidate), let nested = bundle.url(forResource: "parakeet-v2", withExtension: "json") {
                packagedURL = nested
                break
            }
        }
        let url = packagedURL ?? fallback()
        guard let url else {
            throw ModelSetupError.message("The bundled model manifest is missing. Reinstall LocalAudio.")
        }
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try manifest.validate()
        return manifest
    }

    func validate() throws {
        guard schemaVersion == 1, id == "parakeet-v2", repository == "FluidInference/parakeet-tdt-0.6b-v2-coreml", revision.count == 40,
              revision.allSatisfy({ $0.isHexDigit }), !files.isEmpty,
              license == "CC-BY-4.0", licenseURL.scheme == "https", !attribution.isEmpty else {
            throw ModelSetupError.message("The bundled model manifest is invalid.")
        }
        var paths = Set<String>()
        var sum: Int64 = 0
        for file in files {
            try file.validatePath()
            let digestLength = file.algorithm == .sha256 ? 64 : 40
            guard file.size > 0, file.digest.count == digestLength,
                  file.digest.allSatisfy({ $0.isHexDigit }), paths.insert(file.path).inserted else {
                throw ModelSetupError.message("Invalid or duplicate model asset: \(file.path)")
            }
            let expected = "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)"
            guard file.url.absoluteString == expected else {
                throw ModelSetupError.message("Model asset URL is not pinned to its expected revision: \(file.path)")
            }
            let (next, overflow) = sum.addingReportingOverflow(file.size)
            guard !overflow else { throw ModelSetupError.message("Invalid model download size.") }
            sum = next
        }
        guard totalBytes == sum else { throw ModelSetupError.message("Model download sizes do not match the manifest.") }
        for bundle in Self.requiredBundles {
            for child in ["coremldata.bin", "model.mil", "weights/weight.bin"] {
                guard paths.contains(bundle + "/" + child) else {
                    throw ModelSetupError.message("Required model asset is absent from manifest: \(bundle)/\(child)")
                }
            }
        }
        guard paths.contains("parakeet_vocab.json"), paths.contains("README.md") else {
            throw ModelSetupError.message("The model vocabulary or attribution is absent from the manifest.")
        }
    }

    static let requiredBundles = ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc"]
}

struct ModelManifestFile: Codable, Sendable {
    enum Algorithm: String, Codable, Sendable { case sha256; case gitBlobSHA1 = "git-blob-sha1" }
    let path: String
    let url: URL
    let size: Int64
    let algorithm: Algorithm
    let digest: String

    func validatePath() throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".."
                  && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) }) else {
            throw ModelSetupError.message("Unsafe model asset path: \(path)")
        }
    }
}

enum ModelSetupError: LocalizedError, Sendable {
    case message(String)
    case notSelected
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .notSelected: return "Download the English model or choose an existing local model folder."
        }
    }
}

enum ModelFileIntegrity {
    /// Uses bounded chunks for both large LFS SHA-256 and Git blob SHA-1.
    static func verify(_ url: URL, expected: ModelManifestFile) throws {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true,
              Int64(info.fileSize ?? -1) == expected.size else {
            throw ModelSetupError.message("Model file size/type is incorrect: \(expected.path). Retry installation.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha256 = SHA256()
        var sha1 = Insecure.SHA1()
        if expected.algorithm == .gitBlobSHA1 {
            sha1.update(data: Data("blob \(expected.size)\0".utf8))
        }
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            if expected.algorithm == .sha256 { sha256.update(data: bytes) } else { sha1.update(data: bytes) }
        }
        let actual = expected.algorithm == .sha256
            ? sha256.finalize().map { String(format: "%02x", $0) }.joined()
            : sha1.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected.digest.lowercased() else {
            throw ModelSetupError.message("Model checksum failed: \(expected.path). This model file was rejected. Download or repair the English model in Settings.")
        }
    }
}
