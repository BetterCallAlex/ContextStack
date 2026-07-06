import Foundation
import NaturalLanguage

/// Session-topic awareness (opt-in, `contentLearning`): embed what was
/// recently pasted (the capture archive — content the user already chose to
/// capture; the clipboard itself is never read for this) and compare picker
/// candidates against it. "Deep in the thesis notebook → the thesis window
/// outranks the football tab regardless of recency."
///
/// Apple `NLEmbedding` sentence vectors: on-device, no download, ~ms per
/// call. The similarity lands as a *bucketed learned feature* in the window
/// ranker — if topic match doesn't predict this user's picks, its weights
/// stay near zero. No static boost.
enum TopicModel {
    private static let sessionWindow: TimeInterval = 2 * 3600
    private static let maxCaptures = 10
    private static let snippetChars = 1000
    private static var topicCache: (vector: [Double], at: Date)?

    private static let embedding: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)

    static var available: Bool { embedding != nil }

    // ------------------------------------------------------------- vectors

    static func vector(for text: String) -> [Double]? {
        guard Config.contentLearning, let embedding else { return nil }
        let snippet = String(text.prefix(snippetChars))
            .replacingOccurrences(of: "\n", with: " ")
        guard !snippet.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return embedding.vector(for: snippet)
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na * nb).squareRoot()
        return denom > 0 ? dot / denom : 0
    }

    // -------------------------------------------------------- session topic

    /// Mean embedding of the session's recent pastes; cached 60 s. Call
    /// `refreshTopicVector()` from a background queue at hotkey time.
    static func topicVector() -> [Double]? {
        guard Config.contentLearning else { return nil }
        if let c = topicCache, Date().timeIntervalSince(c.at) < 60 { return c.vector }
        return nil
    }

    static func refreshTopicVector(dir: String = Config.captureDir) {
        guard Config.contentLearning else { return }
        if let c = topicCache, Date().timeIntervalSince(c.at) < 60 { return }
        let cutoff = Date().addingTimeInterval(-sessionWindow)
        let recent = CaptureArchive.recent(limit: maxCaptures, dir: dir)
            .filter { !$0.isImage && $0.date > cutoff }
        var vectors: [[Double]] = []
        for item in recent {
            guard let text = try? String(contentsOf: item.url, encoding: .utf8) else { continue }
            // Strip our capture header — it's boilerplate, not topic.
            let body = text.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n")
            if let v = vector(for: body.isEmpty ? text : body) { vectors.append(v) }
        }
        guard let dim = vectors.first?.count else {
            topicCache = nil
            return
        }
        var mean = [Double](repeating: 0, count: dim)
        for v in vectors where v.count == dim {
            for i in 0..<dim { mean[i] += v[i] }
        }
        for i in 0..<dim { mean[i] /= Double(vectors.count) }
        DispatchQueue.main.async { topicCache = (mean, Date()) }
    }

    // ------------------------------------------------------------- features

    /// Bucketed similarity — a hashed feature name the ranker learns weights
    /// for, or nil when content learning is off / no data.
    static func bucket(candidateVector: [Double]?) -> String? {
        guard let topic = topicVector(), let candidate = candidateVector else { return nil }
        let sim = cosine(topic, candidate)
        if sim > 0.6 { return "high" }
        if sim > 0.35 { return "mid" }
        return "low"
    }
}
