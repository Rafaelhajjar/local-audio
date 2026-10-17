import Foundation
import AVFoundation
import CryptoKit

public struct RecordingMetadata: Codable, Equatable, Sendable {
    public var version = 1
    public var id: String
    public var title: String
    public var recordedAt: Date
    public var importedFrom: String?
    public var sourceHash: String?

    public init(id: String = UUID().uuidString, title: String, recordedAt: Date, importedFrom: String? = nil, sourceHash: String? = nil) {
        self.id = id; self.title = title; self.recordedAt = recordedAt
        self.importedFrom = importedFrom; self.sourceHash = sourceHash
    }
}

public struct AudioRecording: Identifiable, Equatable, Sendable {
    public let url: URL
    public var metadata: RecordingMetadata
    public let duration: Double
    public let bytes: Int64
    public var id: String { metadata.id }
    public var title: String { metadata.title }
    public var date: Date { metadata.recordedAt }
    public var transcriptURL: URL { Self.transcriptURL(for: url) }
    public static func transcriptURL(for audio: URL) -> URL { audio.appendingPathExtension("transcript.json") }
    public static func metadataURL(for audio: URL) -> URL { audio.appendingPathExtension("localaudio.json") }
}

public struct TranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var text: String
    public init(id: Int, start: Double, end: Double, text: String) {
        self.id = id; self.start = start; self.end = end; self.text = text
    }
}

public struct LocalTranscript: Codable, Equatable, Sendable {
    public var version = 1
    public var text: String
    public var segments: [TranscriptSegment]
    public var model: String
    public var createdAt: Date
    public init(text: String, segments: [TranscriptSegment], model: String = "Parakeet TDT v2 (English)", createdAt: Date = Date()) {
        self.text = text; self.segments = segments; self.model = model; self.createdAt = createdAt
    }
    public func exportedText(title: String, recordedAt: Date) -> String {
        let stamp = ISO8601DateFormatter().string(from: recordedAt)
        return title + "\nRecorded: " + stamp + "\nTranscribed locally with " + model + "\n\n" + text + "\n"
    }
}

public enum LocalAudioError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

public enum PrivateJSON {
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

public actor RecordingLibrary {
    public static let supportedExtensions: Set<String> = ["caf", "wav", "m4a", "mp3", "aiff", "aif", "flac", "aac"]
    public let folder: URL
    public init(folder: URL) { self.folder = folder.standardizedFileURL }

    public func scan() throws -> [AudioRecording] {
        try scanWithWarnings().recordings
    }

    public func scanWithWarnings() throws -> (recordings: [AudioRecording], warnings: [String]) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) else { return ([], []) }
        guard isDirectory.boolValue else { throw LocalAudioError.message("The recording location is a file. Choose a folder in Settings.") }
        var scanError: Error?
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in scanError = error; return false }) else {
            throw LocalAudioError.message("Cannot open the recording folder. Choose it again in Settings.")
        }
        var result: [AudioRecording] = []
        var warnings: [String] = []
        var identities = Set<String>()
        for case let url as URL in enumerator where Self.supportedExtensions.contains(url.pathExtension.lowercased()) {
            do {
                let item = try describe(url)
                guard identities.insert(item.id).inserted else {
                    warnings.append(url.lastPathComponent + ": duplicate recording identity. Move its .localaudio.json sidecar aside to treat this copy as a separate recording.")
                    continue
                }
                result.append(item)
            }
            catch { warnings.append(url.lastPathComponent + ": " + error.localizedDescription) }
        }
        if let scanError { throw scanError }
        return (result.sorted { $0.date > $1.date }, warnings)
    }

    public func describe(_ url: URL) throws -> AudioRecording {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey])
        guard values.isRegularFile == true else { throw LocalAudioError.message("Choose an audio file.") }
        let audio = try AVAudioFile(forReading: url)
        let rate = audio.processingFormat.sampleRate
        guard rate > 0, audio.length > 0 else { throw LocalAudioError.message("The audio file is empty or is still being saved.") }
        let metadataURL = AudioRecording.metadataURL(for: url)
        let metadata: RecordingMetadata
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            metadata = try PrivateJSON.read(RecordingMetadata.self, from: metadataURL)
            guard metadata.version == 1 else { throw LocalAudioError.message("This recording metadata needs a newer app version.") }
        } else {
            let fallbackID = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
            metadata = RecordingMetadata(id: fallbackID, title: url.deletingPathExtension().lastPathComponent, recordedAt: values.creationDate ?? Date())
        }
        return AudioRecording(url: url, metadata: metadata, duration: Double(audio.length) / rate, bytes: Int64(values.fileSize ?? 0))
    }

    @discardableResult
    public func registerSaved(_ url: URL) throws -> AudioRecording {
        let item = try describe(url)
        if !FileManager.default.fileExists(atPath: AudioRecording.metadataURL(for: url).path) {
            let formatter = DateFormatter(); formatter.dateFormat = "MMM d, h:mm a"
            let metadata = RecordingMetadata(title: "Recording · " + formatter.string(from: item.date), recordedAt: item.date)
            try PrivateJSON.write(metadata, to: AudioRecording.metadataURL(for: url))
        }
        return try describe(url)
    }

    public func importAudio(_ source: URL) throws -> AudioRecording {
        guard Self.supportedExtensions.contains(source.pathExtension.lowercased()) else {
            throw LocalAudioError.message("This audio format is not supported. Try WAV, CAF, M4A, MP3, AIFF or FLAC.")
        }
        let original = try describe(source)
        if source.standardizedFileURL.path.hasPrefix(folder.path + "/") { return original }
        let before = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let hash = try Self.hash(source)
        for item in try scan() where item.metadata.sourceHash == hash { return item }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = folder.appendingPathComponent(UUID().uuidString + "." + source.pathExtension.lowercased())
        let staging = folder.appendingPathComponent(".import-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate,
              try Self.hash(staging) == hash else { throw LocalAudioError.message("The source changed during import. Wait for the recording or transfer to finish, then try again.") }
        try FileManager.default.moveItem(at: staging, to: destination)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            let metadata = RecordingMetadata(title: source.deletingPathExtension().lastPathComponent, recordedAt: original.date, importedFrom: source.lastPathComponent, sourceHash: hash)
            try PrivateJSON.write(metadata, to: AudioRecording.metadataURL(for: destination))
            return try describe(destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: AudioRecording.metadataURL(for: destination))
            throw error
        }
    }

    public func update(_ item: AudioRecording, title: String, date: Date) throws {
        var metadata = item.metadata
        metadata.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if metadata.title.isEmpty { metadata.title = item.url.deletingPathExtension().lastPathComponent }
        metadata.recordedAt = date
        try PrivateJSON.write(metadata, to: AudioRecording.metadataURL(for: item.url))
    }

    public static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { digest.update(data: chunk) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct TranscriptionJob: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case queued, running, failed }
    public var id: String
    public var audioURL: URL
    public var title: String
    public var status: Status
    public var error: String?
    public init(recording: AudioRecording) {
        id = recording.id; audioURL = recording.url; title = recording.title; status = .queued; error = nil
    }
}

public struct LaunchPaths: Sendable {
    public let data: URL
    public let recordingsOverride: URL?
    public let isIsolated: Bool
    public static func parse(_ arguments: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> LaunchPaths {
        let keys = Set(["--data-folder", "--recordings-folder"])
        var values: [String: String] = [:]; var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else { index += 1; continue }
            guard keys.contains(argument), values[argument] == nil, index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("-"), !arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LocalAudioError.message("Use --data-folder PATH and --recordings-folder PATH for isolated launches. Invalid option: " + argument)
            }
            values[argument] = arguments[index + 1]; index += 2
        }
        func url(_ text: String) -> URL { URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL }
        return LaunchPaths(data: values["--data-folder"].map(url) ?? home.appendingPathComponent("Library/Application Support/LocalAudio"), recordingsOverride: values["--recordings-folder"].map(url), isIsolated: values["--data-folder"] != nil)
    }
}
