#!/usr/bin/env swift
// Read-only local capture evidence. Does not upload or modify audio.
import AVFoundation
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: swift scripts/inspect-audio.swift /path/to/recording.caf\n".utf8))
    exit(2)
}
do {
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let audio = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 65_536) else {
        throw NSError(domain: "LocalAudioInspection", code: 1)
    }
    var decoded: Int64 = 0
    var peak: Float = 0
    while audio.framePosition < audio.length {
        try audio.read(into: buffer)
        guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
        decoded += Int64(buffer.frameLength)
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                let value = channels[channel][frame]
                guard value.isFinite else { throw NSError(domain: "LocalAudioNonfinitePCM", code: 2) }
                peak = max(peak, abs(value))
            }
        }
    }
    let result: [String: Any] = ["file":url.lastPathComponent,"frames":audio.length,"decodedFrames":decoded,
        "sampleRate":audio.fileFormat.sampleRate,"channels":audio.fileFormat.channelCount,
        "durationSeconds":Double(audio.length)/audio.fileFormat.sampleRate,"peakAmplitude":peak,
        "allZeroPCM":peak == 0,"fullyDecoded":decoded == audio.length]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data); print()
    guard decoded == audio.length, decoded > 0 else { exit(1) }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
}
