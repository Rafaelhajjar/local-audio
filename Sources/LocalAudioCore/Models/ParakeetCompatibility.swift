import Foundation

/// This app supports the recognized pinned v2 joint graph. Scalar joint I/O
/// shapes or vocabulary length alone cannot distinguish every v2/v3 conversion.
public enum ParakeetCompatibility {
    public static func validateV2Joint(in folder: URL) throws {
        let manifest = try ModelManifest.bundled()
        guard let expected = manifest.files.first(where: { $0.path == "JointDecision.mlmodelc/model.mil" }) else {
            throw ModelSetupError.message("The app's model compatibility manifest is incomplete. Reinstall LocalAudio from a complete app download.")
        }
        try validateV2Joint(in: folder, expected: expected)
    }

    static func validateV2Joint(in folder: URL, expected: ModelManifestFile) throws {
        guard folder.isFileURL, expected.path == "JointDecision.mlmodelc/model.mil" else {
            throw ModelSetupError.message("Select a local folder containing the supported Parakeet v2 Core ML model pack.")
        }
        do {
            try ModelFileIntegrity.verify(folder.appendingPathComponent(expected.path), expected: expected)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ModelSetupError.message("The selected folder has a missing, incomplete or unsupported Parakeet joint graph. "
                + "Download the English model in Settings, or choose the supported Parakeet v2 pack. "
                + "Other v2/v3 conversions are not supported; this folder has not been changed. "
                + "JointDecision.mlmodelc/model.mil: \(error.localizedDescription)")
        }
    }
}
