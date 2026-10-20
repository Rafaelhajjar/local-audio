import Foundation
import AVFoundation
import LocalAudioCore

/// Read-only extraction for isolated evaluation. This neither reads nor enrolls
/// profiles, and deliberately uses the same recipe as normal speaker analysis.
enum BatchClipEmbeddings {
    static let recipeID = "localaudio-clip-v1-native-crop-resample16k-zero-tail10s-mask589-l2"

    struct Request: Decodable {
        let version: Int
        let clips: [Clip]
        let diagnostics: Bool?
        let paddingMode: ClipPaddingMode?
    }
    struct Clip: Decodable {
        let id: String
        let audioURL: URL
        let start: Double
        let end: Double
        let audioHash: String
    }
    struct Result: Encodable {
        let version = 1
        let modelID: String
        let recipeID: String
        let paddingMode: String
        let diagnosticRecipeID: String?
        let clips: [ClipResult]
    }
    struct ClipResult: Encodable {
        let id: String
        var embedding: [Float]?
        var error: String?
        var diagnostics: ClipSegmentationDiagnostics?
        var diagnosticsError: String?
    }
    private struct Snapshot {
        let size: Int
        let modified: Date?
        let hash: String
    }

    static func run(requestURL: URL, modelsURL: URL, outputURL: URL) throws {
        let request = try PrivateJSON.read(Request.self, from: requestURL)
        guard request.version == 1, !request.clips.isEmpty, request.clips.count <= 10_000 else {
            throw Speakers.failure("Expected a version-1 clip request containing 1–10000 clips.")
        }
        var ids = Set<String>()
        for clip in request.clips {
            guard !clip.id.isEmpty, ids.insert(clip.id).inserted, clip.audioURL.isFileURL,
                  clip.audioHash.count == 64,
                  clip.audioHash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                throw Speakers.failure("Every clip requires a unique nonempty ID, a local audio URL, and its SHA-256 audioHash.")
            }
        }
        let sources = request.clips.map { $0.audioURL.standardizedFileURL.resolvingSymlinksInPath() }
        let destination = outputURL.resolvingSymlinksInPath()
        let models = modelsURL.resolvingSymlinksInPath()
        guard destination != requestURL.resolvingSymlinksInPath(), !sources.contains(destination),
              destination != models, !destination.path.hasPrefix(models.path + "/"),
              outputURL.pathExtension.lowercased() == "json" else {
            throw Speakers.failure("Batch output must be a new JSON file, outside models, and separate from the request and every source audio file.")
        }
        try Speakers.requireNewOutput(outputURL)

        // Preserve input order while reading and hashing each distinct source
        // only once before extraction and once again before publishing results.
        var sourceOrder: [URL] = []
        var groups: [URL: [Int]] = [:]
        for (index, source) in sources.enumerated() {
            if groups[source] == nil { sourceOrder.append(source) }
            groups[source, default: []].append(index)
        }
        var results = request.clips.map { ClipResult(id: $0.id, error: "Clip was not processed.") }
        var snapshots: [URL: Snapshot] = [:]
        var durations: [URL: Double] = [:]
        for source in sourceOrder {
            try Task.checkCancellation()
            let indices = groups[source]!
            do {
                let hashes = Set(indices.map { request.clips[$0].audioHash.lowercased() })
                guard hashes.count == 1 else { throw Speakers.failure("Conflicting source hashes were supplied for the same audio file.") }
                let snapshot = try snapshot(source)
                guard snapshot.hash == hashes.first! else { throw Speakers.failure("Source audio does not match the requested SHA-256. No clips from this file were extracted.") }
                let audio = try AVAudioFile(forReading: source)
                let duration = Double(audio.length) / audio.processingFormat.sampleRate
                guard duration.isFinite, duration > 0 else { throw Speakers.failure("Source audio is empty or has an invalid sample rate.") }
                snapshots[source] = snapshot
                durations[source] = duration
            } catch is CancellationError { throw CancellationError() }
            catch {
                for index in indices { results[index].error = error.localizedDescription }
            }
        }

        let localModels = try LocalSpeakerModels.load(modelsURL)
        let embedder = try ClipEmbedder(models: localModels)
        try embedder.validateNativeIO()
        for source in sourceOrder where snapshots[source] != nil {
            for index in groups[source]! {
                try Task.checkCancellation()
                let clip = request.clips[index]
                do {
                    let length = clip.end - clip.start
                    guard clip.start.isFinite, clip.end.isFinite, clip.start >= 0,
                          length >= 2, length <= 5.000_000_001,
                          clip.end <= durations[source]! + 0.001 else {
                        throw Speakers.failure("Clip bounds must describe 2–5 seconds inside the source audio. No automatic recentering or trimming was applied.")
                    }
                    let vector = try embedder.embedForExperiment(source: source, span: .init(start: clip.start, end: clip.end),
                        paddingMode: request.paddingMode ?? .zero)
                    results[index].embedding = vector
                    results[index].error = vector == nil
                        ? "Clip failed the baseline signal or finite 256-dimensional embedding checks." : nil
                    if request.diagnostics == true {
                        do {
                            results[index].diagnostics = try embedder.diagnostics(source: source, span: .init(start: clip.start, end: clip.end))
                        } catch is CancellationError { throw CancellationError() }
                        catch { results[index].diagnosticsError = error.localizedDescription }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { results[index].error = error.localizedDescription }
            }
        }
        for source in sourceOrder {
            guard let before = snapshots[source] else { continue }
            try Task.checkCancellation()
            do {
                let after = try snapshot(source)
                guard before.size == after.size, before.modified == after.modified, before.hash == after.hash else {
                    throw Speakers.failure("Source audio changed during extraction. All clip vectors from this file were discarded.")
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                for index in groups[source]! {
                    results[index].embedding = nil
                    results[index].error = error.localizedDescription
                    results[index].diagnostics = nil
                    results[index].diagnosticsError = request.diagnostics == true
                        ? "Source verification failed; diagnostics were discarded." : nil
                }
            }
        }
        try Task.checkCancellation()
        let mode = request.paddingMode ?? .zero
        try publish(Result(modelID: ModelPack.speakers.modelID, recipeID: mode.recipeID, paddingMode: mode.rawValue,
            diagnosticRecipeID: request.diagnostics == true ? ClipSegmentationDiagnostics.recipeID : nil, clips: results), to: outputURL)
        print("Local clip embeddings saved (\(results.filter { $0.embedding != nil }.count)/\(results.count) usable). No profiles were read or changed.")
    }

    private static func publish(_ result: Result, to destination: URL) throws {
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".clip-results-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: staging) }
        try PrivateJSON.write(result, to: staging)
        try Task.checkCancellation()
        try Speakers.requireNewOutput(destination)
        // Link a complete mode-0600 sibling atomically. Unlike a check followed
        // by an overwriting rename, this also refuses a destination created by
        // another batch between the safety check and publication.
        do { try FileManager.default.linkItem(at: staging, to: destination) }
        catch {
            throw Speakers.failure("Cannot publish a new batch result without replacing an existing file. Choose a new path on a local filesystem that supports links. " + error.localizedDescription)
        }
    }

    private static func snapshot(_ source: URL) throws -> Snapshot {
        let before = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard before.isRegularFile == true, let size = before.fileSize, size > 0 else {
            throw Speakers.failure("Source audio is missing, empty or not a regular file.")
        }
        let hash = try RecordingLibrary.hash(source)
        let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard size == after.fileSize, before.contentModificationDate == after.contentModificationDate else {
            throw Speakers.failure("Source audio changed while its SHA-256 was being checked.")
        }
        return Snapshot(size: size, modified: before.contentModificationDate, hash: hash)
    }
}
