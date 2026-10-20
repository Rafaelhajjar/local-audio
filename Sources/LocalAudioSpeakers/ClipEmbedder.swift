import Foundation
import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import class FluidAudio.AudioConverter
import LocalAudioCore

/// Evaluation-only padding modes. Repetition adds no independent voice evidence.
enum ClipPaddingMode: String, Decodable {
    case zero
    case repeatOriginalMask = "repeat-original-mask"
    case repeatFullMask = "repeat-full-mask"

    var recipeID: String {
        switch self {
        case .zero: return BatchClipEmbeddings.recipeID
        case .repeatOriginalMask: return "localaudio-clip-v1-native-crop-resample16k-periodic10s-original-mask589-l2"
        case .repeatFullMask: return "localaudio-clip-v1-native-crop-resample16k-periodic10s-full-mask589-l2"
        }
    }
}

final class ClipEmbedder {
    private let models: OfflineDiarizerModels
    private let converter = AudioConverter(sampleRate: 16_000)
    private let sampleCount = 160_000
    private let weightFrames = 589

    init(models: OfflineDiarizerModels) throws {
        self.models = models
        func input(_ model: MLModel, _ name: String, last: Int) throws {
            guard let constraint = model.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint,
                  constraint.dataType == .float32, constraint.shape.last?.intValue == last else {
                throw Speakers.failure("Unsupported speaker-model input \(name). Install the supported Speaker Models in Settings.")
            }
        }
        try input(models.segmentationModel, "audio", last: sampleCount)
        try input(models.fbankModel, "audio", last: sampleCount)
        try input(models.embeddingModel, "fbank_features", last: 998)
        try input(models.embeddingModel, "weights", last: weightFrames)
        try input(models.pldaRhoModel, "embeddings", last: 256)
        for (model, name) in [(models.segmentationModel, "log_probs"), (models.fbankModel, "fbank_features"),
                              (models.embeddingModel, "embedding"), (models.pldaRhoModel, "rho")] {
            guard model.modelDescription.outputDescriptionsByName[name]?.type == .multiArray else {
                throw Speakers.failure("Unsupported speaker-model output \(name). Repair Speaker Models in Settings.")
            }
        }
    }

    /// Predict generated, non-speech data once to validate actual native I/O.
    /// This synthetic vector is discarded and can never become a voice example.
    func validateNativeIO() throws {
        var synthetic = [Float](repeating: 0, count: sampleCount)
        for index in synthetic.indices {
            let phase = Double(index)
            synthetic[index] = Float(0.03 * sin(phase * 0.019) + 0.01 * sin(phase * 0.041))
        }
        let audio = try audioArray(synthetic)
        let segmentation = try models.segmentationModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: audio)]))
        guard let logits = segmentation.featureValue(for: "log_probs")?.multiArrayValue,
              logits.shape.map({ $0.intValue }) == [1, 589, 7] else { throw Speakers.failure("Speaker segmentation produced an unsupported native shape.") }
        let raw = try embedding(samples: synthetic)
        guard raw.count == 256, raw.allSatisfy({ $0.isFinite }) else { throw Speakers.failure("Speaker embedding output must contain 256 finite values.") }
        let input = try MLMultiArray(shape: [1, 256], dataType: .float32)
        for index in raw.indices { input[index] = NSNumber(value: raw[index]) }
        let output = try models.pldaRhoModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["embeddings": MLFeatureValue(multiArray: input)]))
        guard let rho = output.featureValue(for: "rho")?.multiArrayValue, rho.count == 128,
              (0..<rho.count).allSatisfy({ rho[$0].doubleValue.isFinite }) else {
            throw Speakers.failure("Speaker PLDA output must contain 128 finite values.")
        }
    }

    func embed(source: URL, span: SpeakerSampleSpan) throws -> [Float]? {
        let file = try AVAudioFile(forReading: source)
        let rate = file.processingFormat.sampleRate
        guard rate.isFinite, rate > 0, span.start >= 0, span.end - span.start >= 2, span.end - span.start <= 5.0001 else { return nil }
        let first = min(file.length, AVAudioFramePosition((span.start * rate).rounded(.down)))
        let last = min(file.length, AVAudioFramePosition((span.end * rate).rounded(.up)))
        guard last > first else { return nil }
        file.framePosition = first
        let frames = AVAudioFrameCount(last - first)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw Speakers.failure("Could not allocate a short speaker preview buffer.")
        }
        try file.read(into: buffer, frameCount: frames)
        let samples = try converter.resampleBuffer(buffer)
        guard SpeakerClipPolicy.hasUsableSignal(samples) else { return nil }
        return SpeakerClipPolicy.normalizedEmbedding(try embedding(samples: samples))
    }

    /// Batch-only diagnostics repeat the baseline crop/resample operation so
    /// production extraction stays byte-for-byte unchanged. No speech score is
    /// used to change an embedding or decide a person's identity.
    func diagnostics(source: URL, span: SpeakerSampleSpan) throws -> ClipSegmentationDiagnostics {
        let samples = try experimentSamples(source: source, span: span)
        try Task.checkCancellation()
        let audio = try audioArray(samples)
        let result = try models.segmentationModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: audio)]))
        guard let output = result.featureValue(for: "log_probs")?.multiArrayValue,
              output.shape.map({ $0.intValue }) == [1, 589, 7] else {
            throw Speakers.failure("Segmentation diagnostics require native shape [1,589,7].")
        }
        let rows = (0..<589).map { frame in
            (0..<7).map { cls in output[[0, NSNumber(value: frame), NSNumber(value: cls)]].doubleValue }
        }
        return try ClipSegmentationDiagnostics.calculate(samples: samples, logProbabilities: rows)
    }

    /// Separate from production embed(). The zero case delegates to that exact
    /// baseline; both repeated cases change input context, never source audio.
    func embedForExperiment(source: URL, span: SpeakerSampleSpan, paddingMode: ClipPaddingMode) throws -> [Float]? {
        if paddingMode == .zero { return try embed(source: source, span: span) }
        let original = try experimentSamples(source: source, span: span)
        guard SpeakerClipPolicy.hasUsableSignal(original) else { return nil }
        let repeated = (0..<sampleCount).map { original[$0 % original.count] }
        let audio = try audioArray(repeated)
        let fbank = try models.fbankModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: audio)]))
        guard let features = fbank.featureValue(for: "fbank_features")?.multiArrayValue,
              features.shape.map({ $0.intValue }) == [1, 1, 80, 998] else {
            throw Speakers.failure("Experimental FBank produced an unsupported native shape.")
        }
        let weights = try MLMultiArray(shape: [1, NSNumber(value: weightFrames)], dataType: .float32)
        let active = paddingMode == .repeatFullMask ? weightFrames
            : max(1, min(weightFrames, Int((Double(min(original.count, sampleCount)) / Double(sampleCount) * Double(weightFrames)).rounded())))
        for index in 0..<weightFrames { weights[index] = NSNumber(value: index < active ? Float(1) : Float(0)) }
        let result = try models.embeddingModel.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "fbank_features": MLFeatureValue(multiArray: features), "weights": MLFeatureValue(multiArray: weights)
        ]))
        guard let output = result.featureValue(for: "embedding")?.multiArrayValue, output.count == 256 else {
            throw Speakers.failure("Experimental speaker model produced an invalid embedding size.")
        }
        return SpeakerClipPolicy.normalizedEmbedding((0..<256).map { output[$0].floatValue })
    }

    /// Copy of the baseline read geometry, used by batch experiments only.
    private func experimentSamples(source: URL, span: SpeakerSampleSpan) throws -> [Float] {
        let file = try AVAudioFile(forReading: source)
        let rate = file.processingFormat.sampleRate
        guard rate.isFinite, rate > 0, span.start >= 0, span.end - span.start >= 2, span.end - span.start <= 5.0001 else {
            throw Speakers.failure("Diagnostics require the same valid 2–5 second baseline clip.")
        }
        let first = min(file.length, AVAudioFramePosition((span.start * rate).rounded(.down)))
        let last = min(file.length, AVAudioFramePosition((span.end * rate).rounded(.up)))
        guard last > first else { throw Speakers.failure("The diagnostic clip has no readable audio frames.") }
        file.framePosition = first
        let frames = AVAudioFrameCount(last - first)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw Speakers.failure("Could not allocate a short diagnostic buffer.")
        }
        try file.read(into: buffer, frameCount: frames)
        return try converter.resampleBuffer(buffer)
    }

    private func audioArray(_ samples: [Float]) throws -> MLMultiArray {
        let audio = try MLMultiArray(shape: [1, 1, NSNumber(value: sampleCount)], dataType: .float32)
        for index in 0..<sampleCount { audio[index] = NSNumber(value: index < samples.count ? samples[index] : 0) }
        return audio
    }

    private func embedding(samples: [Float]) throws -> [Float] {
        let audio = try audioArray(samples)
        let fbank = try models.fbankModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: audio)]))
        guard let features = fbank.featureValue(for: "fbank_features")?.multiArrayValue,
              features.shape.map(\.intValue) == [1, 1, 80, 998] else { throw Speakers.failure("Speaker FBank produced an unsupported native shape.") }
        let weights = try MLMultiArray(shape: [1, NSNumber(value: weightFrames)], dataType: .float32)
        let active = max(1, min(weightFrames, Int((Double(min(samples.count, sampleCount)) / Double(sampleCount) * Double(weightFrames)).rounded())))
        for index in 0..<weightFrames { weights[index] = NSNumber(value: index < active ? Float(1) : Float(0)) }
        let result = try models.embeddingModel.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "fbank_features": MLFeatureValue(multiArray: features), "weights": MLFeatureValue(multiArray: weights)
        ]))
        guard let embedding = result.featureValue(for: "embedding")?.multiArrayValue, embedding.count == 256 else {
            throw Speakers.failure("Speaker model produced an invalid embedding size.")
        }
        return (0..<256).map { embedding[$0].floatValue }
    }
}
