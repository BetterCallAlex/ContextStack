import Foundation

/// The shared substrate of every learned head (action ranking, window
/// ranking, and whatever comes next): stable feature hashing, an online
/// pointwise-softmax model, and an append-only jsonl event log with
/// recency-weighted replay. One implementation — heads differ only in how
/// they build candidate feature sets and what they log.
enum LearningCore {
    /// FNV-1a — Swift's Hasher is seeded per process, so it can't be used
    /// for weights that must line up across replays.
    static func hashIndex(_ name: String, dims: Int) -> Int {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in name.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return Int(h % UInt64(dims))
    }

    /// Recency weight for replayed events: 30-day half-life, floored so old
    /// evidence still counts.
    static func replayWeight(ageSeconds: Double) -> Float {
        let halfLife: Double = 30 * 24 * 3600
        return max(0.25, exp2f(Float(-max(0, ageSeconds) / halfLife)))
    }
}

/// Online multinomial logistic regression over hashed sparse features, in
/// pointwise form: each candidate is a set of weight indices; softmax over
/// the candidates actually presented; one SGD step per observation.
///
/// A fixed-class model (the action head) is expressed in the same form by
/// offsetting each class's features into its own weight-matrix row.
struct PointwiseSoftmaxModel {
    private(set) var weights: [Float]
    let learningRate: Float

    init(weightCount: Int, learningRate: Float = 0.15) {
        weights = [Float](repeating: 0, count: weightCount)
        self.learningRate = learningRate
    }

    func score(_ features: [Int]) -> Float {
        var s: Float = 0
        for f in features { s += weights[f] }
        return s
    }

    /// Softmax over the presented candidates, in presentation order.
    func probabilities(candidates: [[Int]]) -> [Float] {
        let raw = candidates.map(score)
        let maxRaw = raw.max() ?? 0
        let exps = raw.map { expf($0 - maxRaw) }
        let sum = max(exps.reduce(0, +), .leastNormalMagnitude)
        return exps.map { $0 / sum }
    }

    /// One SGD step of softmax cross-entropy toward the chosen candidate.
    mutating func train(candidates: [[Int]], chosen: Int, weight: Float = 1) {
        guard candidates.indices.contains(chosen) else { return }
        let probs = probabilities(candidates: candidates)
        for (i, features) in candidates.enumerated() {
            let gradient = probs[i] - (i == chosen ? 1 : 0)
            let step = learningRate * weight * gradient
            for f in features { weights[f] -= step }
        }
    }
}

/// Append-only jsonl event log: the source of truth for a learned head.
/// Weights are caches rebuilt by replaying it, so feature sets can change
/// between versions without losing data.
struct EventLogFile {
    let url: URL?
    private static let maxReplayLines = 5000

    init(filename: String) {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else {
            url = nil
            return
        }
        let dir = base.appendingPathComponent("ContextStack", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(filename)
    }

    init(url: URL?) {
        self.url = url
    }

    func append<E: Encodable>(_ event: E) {
        guard let url, let data = try? JSONEncoder().encode(event) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }

    /// The last N replayable lines, oldest first.
    func replayLines() -> [Data] {
        guard let url,
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n").suffix(Self.maxReplayLines)
            .map { Data($0.utf8) }
    }
}
