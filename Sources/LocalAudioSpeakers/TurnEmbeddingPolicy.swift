import Foundation

/// Geometry and arithmetic for the integrated recipe, independent of Core ML.
/// Overlap subtraction refines the development experiment's labels-only windows.
enum TurnEmbeddingPolicy {
    struct Geometry {
        let start: Double
        let end: Double
        let speakerID: String
    }
    struct Window: Equatable {
        let kind: String
        let start: Double
        let end: Double
    }
    struct Evidence {
        let window: Window
        let vector: [Float]
        let dominantSoloSeconds: Double
    }
    struct Aggregate {
        let vector: [Float]
        let contributing: [Window]
        let representative: Window
    }

    static func windows(for turn: Geometry, among turns: [Geometry]) -> [Window] {
        guard valid(turn) else { return [] }
        let margin = 0.15
        let bounds = Window(kind: "clean", start: turn.start + margin, end: turn.end - margin)
        let exclusions = turns.filter { $0.speakerID != turn.speakerID && valid($0) }.map {
            Window(kind: "excluded", start: $0.start - margin, end: $0.end + margin)
        }
        var clean = [bounds]
        for excluded in exclusions {
            clean = clean.flatMap { span -> [Window] in
                guard excluded.start < span.end, excluded.end > span.start else { return [span] }
                var pieces: [Window] = []
                if excluded.start > span.start {
                    pieces.append(.init(kind: "clean", start: span.start, end: min(span.end, excluded.start)))
                }
                if excluded.end < span.end {
                    pieces.append(.init(kind: "clean", start: max(span.start, excluded.end), end: span.end))
                }
                return pieces
            }
        }
        guard let longest = clean.filter({ $0.end - $0.start >= 2 }).max(by: { $0.end - $0.start < $1.end - $1.start }) else { return [] }
        let duration = min(5, longest.end - longest.start)
        let middle = (longest.start + longest.end) / 2
        var candidates = [Window(kind: "center", start: middle - duration / 2, end: middle + duration / 2)]
        // The evaluated manifest adds these only for original turns >=8 s.
        // A production boundary window must additionally be entirely clean.
        if turn.end - turn.start >= 8 {
            candidates += [Window(kind: "start5", start: bounds.start, end: bounds.start + 5),
                           Window(kind: "end5", start: bounds.end - 5, end: bounds.end)]
        }
        var selected: [Window] = []
        for candidate in candidates {
            guard candidate.start >= bounds.start - 1e-9, candidate.end <= bounds.end + 1e-9,
                  !exclusions.contains(where: { $0.start < candidate.end && $0.end > candidate.start }),
                  !selected.contains(where: { abs($0.start - candidate.start) < 1e-6 && abs($0.end - candidate.end) < 1e-6 }) else { continue }
            selected.append(candidate)
        }
        return selected
    }

    static func aggregate(_ evidence: [Evidence]) -> Aggregate? {
        let usable = evidence.compactMap { item -> (Evidence, [Double])? in
            guard item.dominantSoloSeconds.isFinite, item.dominantSoloSeconds > 0,
                  let vector = unit(item.vector.map(Double.init)) else { return nil }
            return (item, vector)
        }
        let total = usable.reduce(0.0) { $0 + $1.0.dominantSoloSeconds }
        guard total.isFinite, total > 1e-12 else { return nil }
        var mean = [Double](repeating: 0, count: 256)
        var representative: Evidence?
        for (item, vector) in usable {
            for index in 0..<256 { mean[index] += vector[index] * item.dominantSoloSeconds }
            if representative == nil || item.dominantSoloSeconds > representative!.dominantSoloSeconds { representative = item }
        }
        guard let normalized = unit(mean.map { $0 / total }), let representative else { return nil }
        return Aggregate(vector: normalized.map(Float.init), contributing: usable.map { $0.0.window },
                         representative: representative.window)
    }

    private static func valid(_ geometry: Geometry) -> Bool {
        geometry.start.isFinite && geometry.end.isFinite && geometry.start >= 0 && geometry.end > geometry.start
    }
    private static func unit(_ values: [Double]) -> [Double]? {
        guard values.count == 256, values.allSatisfy({ $0.isFinite }) else { return nil }
        let norm = sqrt(values.reduce(0.0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 1e-8 else { return nil }
        return values.map { $0 / norm }
    }
}
