import Foundation
import AVFoundation
import LocalAudioCore

enum RefreshTurnEmbeddings {
    /// Re-extract saved geometry only. A person ID is never read to choose a
    /// vector, emitted, or written to a profile by this helper.
    static func run(requestURL: URL, modelsURL: URL, outputURL: URL) throws {
        let request = try PrivateJSON.read(VoiceEmbeddingRefreshRequest.self, from: requestURL)
        let analysis = request.analysis
        guard request.audioURL.isFileURL, !analysis.recordingID.isEmpty,
              analysis.audioHash.count == 64,
              analysis.audioHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              analysis.modelID == ModelPack.speakers.modelID,
              (analysis.version == 1 && analysis.recipeID == VoiceEmbeddingRecipe.legacy)
                || (analysis.version == 2 && analysis.recipeID == VoiceEmbeddingRecipe.current) else {
            throw Speakers.failure("Embedding refresh requires a supported saved analysis, its original local audio and the exact pinned speaker models.")
        }
        let source = request.audioURL.standardizedFileURL.resolvingSymlinksInPath()
        let destination = outputURL.resolvingSymlinksInPath()
        let models = modelsURL.resolvingSymlinksInPath()
        guard destination != source, destination != requestURL.resolvingSymlinksInPath(),
              destination != models, !destination.path.hasPrefix(models.path + "/"),
              outputURL.pathExtension.lowercased() == "json" else {
            throw Speakers.failure("Refreshed embeddings require a new JSON result outside models, separate from the source and request.")
        }
        try Speakers.requireNewOutput(outputURL)
        let before = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard try RecordingLibrary.hash(source) == analysis.audioHash else {
            throw Speakers.failure("The original audio changed. Saved geometry was not refreshed and no labels were changed.")
        }
        let audio = try AVAudioFile(forReading: source)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { throw Speakers.failure("The original recording is empty or unreadable.") }
        var ids = Set<String>()
        for turn in analysis.turns {
            guard !turn.id.isEmpty, ids.insert(turn.id).inserted, !turn.speakerID.isEmpty,
                  turn.start.isFinite, turn.end.isFinite, turn.start >= 0,
                  turn.end > turn.start, turn.end <= duration + 0.001 else {
                throw Speakers.failure("Saved turn geometry is invalid for this original recording. No embedding refresh was saved.")
            }
        }
        let localModels = try LocalSpeakerModels.load(modelsURL)
        let embedder = try ClipEmbedder(models: localModels)
        try embedder.validateNativeIO()
        let turns = try ProductionTurnEmbedder.extract(analysis.turns, source: source, using: embedder)
        let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate,
              try RecordingLibrary.hash(source) == analysis.audioHash else {
            throw Speakers.failure("The original audio changed during embedding refresh. No result was saved.")
        }
        try Task.checkCancellation()
        try Speakers.publish(VoiceAnalysis(recordingID: analysis.recordingID, audioHash: analysis.audioHash,
            modelID: analysis.modelID, turns: turns, recipeID: VoiceEmbeddingRecipe.current), to: outputURL)
        print("Speaker embeddings refreshed locally using unchanged turn geometry. No profile or identity decisions were made.")
    }
}
