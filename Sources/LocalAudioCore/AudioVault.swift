import Foundation
import AVFoundation

extension RecordingLibrary {
    private func requireManagedPath(_ url: URL) throws {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        // Resolve the existing parent too: Foundation may leave /var aliases
        // unresolved when the final audio component has already moved to Trash.
        let parentResolved = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).standardizedFileURL
        guard parentResolved.path.hasPrefix(root),
              (!FileManager.default.fileExists(atPath: url.path) || url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root)),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw LocalAudioError.message("Audio must be inside this recording folder, without a symbolic link.")
        }
        let metadata = AudioRecording.metadataURL(for: url)
        guard (try? metadata.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw LocalAudioError.message("The details sidecar is a symbolic link. Audio has been preserved.")
        }
    }

    /// Files copied into the folder by Finder have no reliable entry timestamp.
    /// Adopt them with a fresh window instead of expiring them immediately.
    public func adoptAudioForRetention(now: Date = Date()) throws {
        for item in try scan() where item.hasAudio && item.metadata.managedAt == nil {
            try requireManagedPath(item.url)
            var current = try describe(item.url)
            guard current.metadata.managedAt == nil else { continue }
            current.metadata.managedAt = now
            try PrivateJSON.write(current.metadata, to: AudioRecording.metadataURL(for: item.url))
        }
    }

    public func setVaulted(_ item: AudioRecording, _ vaulted: Bool) throws {
        try requireManagedPath(item.url)
        var current = try describe(item.url)
        guard current.id == item.id, current.hasAudio else { throw LocalAudioError.message("Restore this audio before saving it to the vault.") }
        current.metadata.vaultedAt = vaulted ? Date() : nil
        try PrivateJSON.write(current.metadata, to: AudioRecording.metadataURL(for: item.url))
    }

    /// The caller supplies the protected identities from the validated voice
    /// library and queued work. Errors loading either list must abort cleanup.
    public func trashAudio(_ item: AudioRecording, protectedIDs: Set<String>,
                           trash: @Sendable (URL) throws -> URL = RecordingLibrary.moveToTrash) throws {
        try requireManagedPath(item.url)
        let current = try describe(item.url)
        guard current.id == item.id, current.metadata == item.metadata, current.hasAudio,
              current.bytes == item.bytes, current.duration == item.duration else {
            throw LocalAudioError.message("This recording changed. Refresh the library before removing audio.")
        }
        guard current.metadata.vaultedAt == nil, !protectedIDs.contains(current.id) else {
            throw LocalAudioError.message("This audio is protected by the vault, a saved voice example or unfinished processing.")
        }
        let textValues = try current.transcriptURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard textValues.isRegularFile == true, textValues.isSymbolicLink != true else { throw LocalAudioError.message("A regular transcript sidecar is required; audio has been kept.") }
        let transcript = try PrivateJSON.read(LocalTranscript.self, from: current.transcriptURL)
        guard transcript.version == 1 else { throw LocalAudioError.message("A readable transcript is required before removing audio.") }
        var receipt = current.metadata
        receipt.audioRemovedAt = Date(); receipt.retainedDuration = current.duration; receipt.retainedBytes = current.bytes
        receipt.removedAudioHash = try Self.hash(item.url)
        receipt.trashedAudioURL = nil
        let metadataURL = AudioRecording.metadataURL(for: item.url)
        // Publish the receipt first so an interruption after moving audio still
        // leaves its transcript discoverable. An interrupted move preserves audio.
        try PrivateJSON.write(receipt, to: metadataURL)
        let trashed: URL
        do { trashed = try trash(item.url) }
        catch {
            if FileManager.default.fileExists(atPath: item.url.path) { try PrivateJSON.write(current.metadata, to: metadataURL) }
            throw error
        }
        receipt.trashedAudioURL = trashed
        do { try PrivateJSON.write(receipt, to: metadataURL) }
        catch { throw LocalAudioError.message("Audio moved to Trash; its transcript is safe. Restore audio using Finder if needed. The Trash receipt could not be saved: " + error.localizedDescription) }
    }

    public static func moveToTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw LocalAudioError.message("macOS did not return a Trash location.") }
        return result as URL
    }

    public func restoreAudio(_ item: AudioRecording) throws {
        try requireManagedPath(item.url)
        var current = try describe(item.url)
        guard current.id == item.id, current.metadata.audioRemovedAt != nil else { throw LocalAudioError.message("No removal receipt was found.") }
        if !current.hasAudio {
            guard let source = current.metadata.trashedAudioURL,
                  let expected = current.metadata.removedAudioHash, try Self.hash(source) == expected else {
                throw LocalAudioError.message("The audio is no longer at its recorded Trash location. Restore it using Finder if available; the transcript is safe.")
            }
            try FileManager.default.moveItem(at: source, to: item.url)
        } else if let expected = current.metadata.removedAudioHash, try Self.hash(item.url) != expected {
            throw LocalAudioError.message("A different audio file now occupies this location. It has not been changed.")
        }
        current.metadata.audioRemovedAt = nil; current.metadata.trashedAudioURL = nil
        current.metadata.removedAudioHash = nil; current.metadata.managedAt = Date()
        try PrivateJSON.write(current.metadata, to: AudioRecording.metadataURL(for: item.url))
    }

    public func savePassage(_ item: AudioRecording, start: Double, end: Double, title: String) throws -> AudioRecording {
        try requireManagedPath(item.url)
        let current = try describe(item.url)
        guard current.id == item.id, current.hasAudio, start.isFinite, end.isFinite,
              start >= 0, end > start, end <= current.duration + 0.001 else {
            throw LocalAudioError.message("Choose a start and end within the available audio.")
        }
        let before = try item.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let source = try AVAudioFile(forReading: item.url)
        let format = source.processingFormat
        let first = AVAudioFramePosition((start * format.sampleRate).rounded(.down))
        let last = min(source.length, AVAudioFramePosition((end * format.sampleRate).rounded(.up)))
        guard last > first else { throw LocalAudioError.message("The selected passage is empty.") }
        let vault = folder.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try requireManagedPath(vault.appendingPathComponent("new.caf"))
        let destination = vault.appendingPathComponent(UUID().uuidString + ".caf")
        let staging = vault.appendingPathComponent(".passage-" + UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: staging) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { throw LocalAudioError.message("Cannot allocate the passage audio buffer.") }
        do {
            let output = try AVAudioFile(forWriting: staging, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            source.framePosition = first
            var remaining = last - first
            while remaining > 0 {
                try source.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, 65_536)))
                guard buffer.frameLength > 0 else { throw LocalAudioError.message("The source ended before the selected passage.") }
                try output.write(from: buffer); remaining -= AVAudioFramePosition(buffer.frameLength)
            }
        }
        let check = try AVAudioFile(forReading: staging)
        let after = try item.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard check.length == last - first, check.processingFormat.channelCount == format.channelCount,
              before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else {
            throw LocalAudioError.message("The audio changed while saving the passage. Try again after it finishes saving.")
        }
        var metadata = RecordingMetadata(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? item.title + " · passage" : title, recordedAt: item.date.addingTimeInterval(start))
        metadata.managedAt = Date(); metadata.vaultedAt = Date(); metadata.clipSourceID = item.id
        metadata.clipStart = Double(first) / format.sampleRate; metadata.clipEnd = Double(last) / format.sampleRate
        try FileManager.default.moveItem(at: staging, to: destination)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            try PrivateJSON.write(metadata, to: AudioRecording.metadataURL(for: destination))
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
        return try describe(destination)
    }
}
