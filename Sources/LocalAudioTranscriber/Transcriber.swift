import Foundation
@preconcurrency import CoreML
import FluidAudio
import LocalAudioCore

@main
struct Transcriber {
    static func main() async {
        ModelHub.offlineMode = true
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args == ["--help"] {
                print("local-audio-transcriber --input AUDIO --models FOLDER --output TRANSCRIPT.json\nlocal-audio-transcriber --validate-model FOLDER")
                return
            }
            if args.count == 2, args[0] == "--validate-model" {
                _ = try load(URL(fileURLWithPath: args[1])); print("Local model is ready."); return
            }
            var options: [String: String] = [:]
            guard args.count == 6 else { throw LocalAudioError.message("Expected --input, --models and --output.") }
            for index in stride(from: 0, to: args.count, by: 2) {
                guard ["--input", "--models", "--output"].contains(args[index]), options[args[index]] == nil else { throw LocalAudioError.message("Invalid or duplicate worker option.") }
                options[args[index]] = args[index + 1]
            }
            guard let input = options["--input"], let folder = options["--models"], let output = options["--output"] else { throw LocalAudioError.message("Missing worker option.") }
            let source = URL(fileURLWithPath: input).standardizedFileURL
            let destination = URL(fileURLWithPath: output).standardizedFileURL
            guard source.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath() else { throw LocalAudioError.message("Transcript output cannot replace the source audio.") }
            let models = try load(URL(fileURLWithPath: folder))
            let manager = AsrManager(); try await manager.loadModels(models)
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(source, decoderState: &state)
            let words = result.tokenTimings.map { buildWordTimings(from: $0) } ?? []
            var segments: [TranscriptSegment] = []
            for word in words {
                if let last = segments.indices.last, word.startTime - segments[last].end < 1.2,
                   segments[last].text.split(separator: " ").count < 30 {
                    segments[last].text += " " + word.word
                    segments[last].end = word.endTime
                } else {
                    segments.append(TranscriptSegment(id: segments.count, start: word.startTime, end: word.endTime, text: word.word))
                }
            }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if segments.isEmpty, !text.isEmpty { segments = [.init(id: 0, start: 0, end: 0, text: text)] }
            try PrivateJSON.write(LocalTranscript(text: text, segments: segments), to: destination)
            print("Transcript saved locally.")
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
        }
    }

    static func load(_ folder: URL) throws -> AsrModels {
        try ParakeetCompatibility.validateV2Joint(in: folder)
        let names = ["Preprocessor", "Encoder", "Decoder", "JointDecision"]
        for name in names {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(name + ".mlmodelc").path, isDirectory: &directory), directory.boolValue else {
                throw LocalAudioError.message("The selected model folder is incomplete. Download the English model in Settings or choose a folder containing the four Core ML models and parakeet_vocab.json.")
            }
        }
        let data = try Data(contentsOf: folder.appendingPathComponent("parakeet_vocab.json"))
        let vocabulary = try ParakeetVocabulary.decodeV2(data)
        func model(_ name: String, cpu: Bool = false) throws -> MLModel {
            let configuration = MLModelConfiguration(); configuration.computeUnits = cpu ? .cpuOnly : .cpuAndNeuralEngine
            return try MLModel(contentsOf: folder.appendingPathComponent(name + ".mlmodelc"), configuration: configuration)
        }
        return try AsrModels(encoder: model("Encoder"), preprocessor: model("Preprocessor", cpu: true), decoder: model("Decoder"), joint: model("JointDecision"), configuration: AsrModels.defaultConfiguration(), vocabulary: vocabulary, version: .v2)
    }
}
