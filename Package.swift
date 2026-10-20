// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalAudio",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "LocalAudio", targets: ["LocalAudioApp"]),
        .executable(name: "local-audio-transcriber", targets: ["LocalAudioTranscriber"]),
        .executable(name: "local-audio-speakers", targets: ["LocalAudioSpeakers"])
    ],
    targets: [
        .target(name: "LocalAudioCore", resources: [.process("Resources")]),
        .executableTarget(name: "LocalAudioApp", dependencies: ["LocalAudioCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "LocalAudioTranscriber", dependencies: ["LocalAudioCore", "FluidAudio"]),
        .executableTarget(name: "LocalAudioSpeakers", dependencies: ["LocalAudioCore", "FluidAudio"]),
        .target(name: "FluidAudio", dependencies: ["FastClusterWrapper", "MachTaskSelfWrapper"],
            path: "vendor/FluidAudio/Sources/FluidAudio", exclude: ["ASR/Parakeet/Unified/benchmark.md"],
            resources: [.process("TTS/LuxTts/G2p/Resources")]),
        .target(name: "FastClusterWrapper", path: "vendor/FluidAudio/Sources/FastClusterWrapper", publicHeadersPath: "include"),
        .target(name: "MachTaskSelfWrapper", path: "vendor/FluidAudio/Sources/MachTaskSelfWrapper", publicHeadersPath: "include"),
        .testTarget(name: "LocalAudioCoreTests", dependencies: ["LocalAudioCore"]),
        .testTarget(name: "LocalAudioAppTests", dependencies: ["LocalAudioApp"]),
        .testTarget(name: "LocalAudioSpeakerTests", dependencies: ["LocalAudioSpeakers", "LocalAudioCore"])
    ],
    cxxLanguageStandard: .cxx17
)
