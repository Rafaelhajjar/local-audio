import Foundation
import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import LocalAudioCore

@main
struct Speakers {
    static func main() async {
        ModelHub.offlineMode = true
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--help"] {
                print("local-audio-speakers --validate-model FOLDER\nlocal-audio-speakers --analyze REQUEST.json --models FOLDER --output RESULT.json\nlocal-audio-speakers --refresh-embeddings REQUEST.json --models FOLDER --output RESULT.json\nlocal-audio-speakers --embed-clips REQUEST.json --models FOLDER --output RESULT.json")
                return
            }
            if arguments.count == 2, arguments[0] == "--validate-model" {
                let models = try LocalSpeakerModels.load(URL(fileURLWithPath: arguments[1]))
                try ClipEmbedder(models: models).validateNativeIO()
                print("Local speaker models loaded and native I/O verified.")
                return
            }
            guard arguments.count == 6 else { throw failure("Expected --analyze, --refresh-embeddings or --embed-clips REQUEST.json --models FOLDER --output RESULT.json.") }
            var options: [String: String] = [:]
            for index in stride(from: 0, to: arguments.count, by: 2) {
                guard ["--analyze", "--refresh-embeddings", "--embed-clips", "--models", "--output"].contains(arguments[index]), options[arguments[index]] == nil,
                      !arguments[index + 1].isEmpty else { throw failure("Invalid or duplicate speaker-worker option.") }
                options[arguments[index]] = arguments[index + 1]
            }
            guard let requestPath = options["--analyze"] ?? options["--refresh-embeddings"] ?? options["--embed-clips"],
                  let modelPath = options["--models"], let outputPath = options["--output"] else {
                throw failure("Missing speaker-worker option.")
            }
            let requestURL = URL(fileURLWithPath: requestPath).standardizedFileURL
            let modelURL = URL(fileURLWithPath: modelPath).standardizedFileURL
            let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
            if options["--embed-clips"] != nil {
                try BatchClipEmbeddings.run(requestURL: requestURL, modelsURL: modelURL, outputURL: outputURL)
                return
            }
            if options["--refresh-embeddings"] != nil {
                try RefreshTurnEmbeddings.run(requestURL: requestURL, modelsURL: modelURL, outputURL: outputURL)
                return
            }
            let request = try PrivateJSON.read(VoiceAnalysisRequest.self, from: requestURL)
            guard request.audioURL.isFileURL, !request.recordingID.isEmpty,
                  request.audioHash.count == 64, request.audioHash.allSatisfy(\.isHexDigit),
                  request.modelID == ModelPack.speakers.modelID,
                  request.recipeID == VoiceEmbeddingRecipe.current else {
                throw failure("The speaker request has an invalid source identity or unsupported model ID. Reanalyze using the selected Speaker Models.")
            }
            let source = request.audioURL.standardizedFileURL
            let resolvedOutput = outputURL.resolvingSymlinksInPath()
            let resolvedModels = modelURL.resolvingSymlinksInPath()
            guard resolvedOutput != source.resolvingSymlinksInPath(), resolvedOutput != requestURL.resolvingSymlinksInPath(),
                  resolvedOutput != resolvedModels, !resolvedOutput.path.hasPrefix(resolvedModels.path + "/"),
                  outputURL.pathExtension.lowercased() == "json" else {
                throw failure("The analysis output must be a separate JSON sidecar, outside model storage, and cannot replace the audio or request.")
            }
            try requireNewOutput(outputURL)
            let before = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard try RecordingLibrary.hash(source) == request.audioHash.lowercased() else {
                throw failure("The audio changed before speaker analysis. Its previous speaker labels were not changed; analyze the current recording again.")
            }
            let models = try LocalSpeakerModels.load(modelURL)
            let clipper = try ClipEmbedder(models: models)
            try clipper.validateNativeIO()
            let audio = try AVAudioFile(forReading: source)
            let duration = Double(audio.length) / audio.processingFormat.sampleRate
            guard duration.isFinite, duration > 0 else { throw failure("The recording is empty or cannot be decoded.") }
            let manager = OfflineDiarizerManager()
            manager.initialize(models: models)
            let segments: [TimedSpeakerSegment]
            do { segments = try await manager.process(source).segments }
            catch OfflineDiarizationError.noSpeechDetected { segments = [] }
            let ordered = segments.filter {
                $0.startTimeSeconds.isFinite && $0.endTimeSeconds.isFinite && $0.endTimeSeconds > $0.startTimeSeconds
            }.sorted {
                if $0.startTimeSeconds == $1.startTimeSeconds { return $0.endTimeSeconds < $1.endTimeSeconds }
                return $0.startTimeSeconds < $1.startTimeSeconds
            }
            var anonymousIDs: [String: String] = [:]
            var turns: [VoiceTurn] = []
            for segment in ordered {
                let start = max(0, Double(segment.startTimeSeconds)), end = min(duration, Double(segment.endTimeSeconds))
                guard end > start else { continue }
                if anonymousIDs[segment.speakerId] == nil { anonymousIDs[segment.speakerId] = "S\(anonymousIDs.count + 1)" }
                turns.append(VoiceTurn(id: "\(request.audioHash.prefix(16))-turn-\(turns.count)", start: start, end: end,
                    speakerID: anonymousIDs[segment.speakerId]!))
            }
            turns = try ProductionTurnEmbedder.extract(turns, source: source, using: clipper)
            let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate,
                  try RecordingLibrary.hash(source) == request.audioHash.lowercased() else {
                throw failure("The audio changed during speaker analysis. No analysis was saved; analyze the current recording again.")
            }
            // Only anonymous clusters and optional clip vectors leave this helper.
            // Human identities live in the app's separate confirmation store.
            try requireNewOutput(outputURL)
            try publish(VoiceAnalysis(recordingID: request.recordingID, audioHash: request.audioHash,
                modelID: request.modelID, turns: turns, recipeID: VoiceEmbeddingRecipe.current), to: outputURL)
            print("Anonymous speaker analysis saved locally (\(turns.count) turns).")
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    static func failure(_ text: String) -> LocalAudioError { .message(text) }

    static func requireNewOutput(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw failure("Speaker analysis output already exists. Choose a new result path; existing audio, labels and profiles are never replaced by this helper.")
        }
    }

    static func publish<T: Encodable>(_ result: T, to destination: URL) throws {
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".speaker-result-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: staging) }
        try PrivateJSON.write(result, to: staging)
        try Task.checkCancellation()
        try requireNewOutput(destination)
        do { try FileManager.default.linkItem(at: staging, to: destination) }
        catch { throw failure("Cannot publish a new speaker result without replacing an existing file. Choose a new local output path. " + error.localizedDescription) }
    }
}
