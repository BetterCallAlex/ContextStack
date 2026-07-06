import Foundation

/// Learns which *window* the user will pick, given the paste target and each
/// entry's app, kind, recency rank and selection state. Same machinery as
/// [ActionRanker] (hashed features, online SGD, replay-from-log), but a
/// pointwise scorer with a single weight vector — windows aren't a fixed
/// class set, so the softmax runs over the presented entries.
///
/// Used to move the picker's preselection highlight, never to reorder the
/// list: recency order is muscle memory, the highlight is the prediction.
final class WindowRanker {
    static let shared = WindowRanker(eventsURL: defaultEventsURL())

    struct EntryFeatures: Codable {
        let src: String
        let kind: String
        let sel: Bool
        /// User manually copied from this app recently (clipboard observer,
        /// opt-in). Optional so older logs replay unchanged.
        var mcopy: Bool? = nil
    }

    private struct Event: Codable {
        let v: Int
        let ts: Double
        let target: String
        let entries: [EntryFeatures]
        let chosen: Int
    }

    private static let dims = 4096
    private static let learningRate: Float = 0.15
    private static let maxReplayEvents = 5000
    private static let replayHalfLife: TimeInterval = 30 * 24 * 3600
    private static let replayWeightFloor: Float = 0.25

    private var weights = [Float](repeating: 0, count: dims)
    private(set) var eventCount = 0
    private let eventsURL: URL?

    init(eventsURL: URL?) {
        self.eventsURL = eventsURL
        if eventsURL != nil { replayLog() }
    }

    private static func defaultEventsURL() -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("ContextStack", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("window-events.jsonl")
    }

    // -------------------------------------------------------------- model

    private static func hashIndex(_ name: String) -> Int {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in name.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return Int(h % UInt64(dims))
    }

    /// No bias feature: a constant cancels in the softmax over entries.
    /// `rank` (recency position) lets the model learn how strong the
    /// recency prior actually is for this user.
    private static func features(target: String, entry: EntryFeatures,
                                 rank: Int) -> [Int] {
        var names = [
            "src:\(entry.src)",
            "tgt+src:\(target)|\(entry.src)",
            "kind:\(entry.kind)",
            "tgt+kind:\(target)|\(entry.kind)",
            "rank:\(min(rank, 4))",
        ]
        if entry.sel {
            names.append("sel:1")
            names.append("sel+src:\(entry.src)")
            names.append("sel+tgt:\(target)")
        }
        if entry.mcopy == true {
            names.append("mcopy:1")
            names.append("mcopy+src:\(entry.src)")
        }
        return names.map(hashIndex)
    }

    private func score(_ feats: [Int]) -> Float {
        var s: Float = 0
        for f in feats { s += weights[f] }
        return s
    }

    /// Softmax over the presented entries, in presentation (recency) order.
    func probabilities(target: String, entries: [EntryFeatures]) -> [Float] {
        let raw = entries.enumerated().map {
            score(Self.features(target: target, entry: $1, rank: $0))
        }
        let maxRaw = raw.max() ?? 0
        let exps = raw.map { expf($0 - maxRaw) }
        let sum = max(exps.reduce(0, +), .leastNormalMagnitude)
        return exps.map { $0 / sum }
    }

    /// Predicted index once there's enough evidence and real signal —
    /// callers keep the default (0, most recent) otherwise.
    func predictedIndex(target: String, entries: [EntryFeatures]) -> Int? {
        guard eventCount >= 20, entries.count > 1 else { return nil }
        let probs = probabilities(target: target, entries: entries)
        guard let best = probs.indices.max(by: { probs[$0] < probs[$1] }),
              probs[best] > 1.5 / Float(entries.count) else { return nil }
        return best
    }

    private func train(target: String, entries: [EntryFeatures], chosen: Int,
                       weight: Float) {
        guard entries.indices.contains(chosen) else { return }
        let probs = probabilities(target: target, entries: entries)
        for (i, entry) in entries.enumerated() {
            let gradient = probs[i] - (i == chosen ? 1 : 0)
            let step = Self.learningRate * weight * gradient
            for f in Self.features(target: target, entry: entry, rank: i) {
                weights[f] -= step
            }
        }
        eventCount += 1
    }

    func record(target: String, entries: [EntryFeatures], chosen: Int) {
        let event = Event(v: 1, ts: Date().timeIntervalSince1970,
                          target: target, entries: entries, chosen: chosen)
        if let eventsURL, let data = try? JSONEncoder().encode(event) {
            if !FileManager.default.fileExists(atPath: eventsURL.path) {
                FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: eventsURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data + Data("\n".utf8))
            }
        }
        train(target: target, entries: entries, chosen: chosen, weight: 1)
    }

    private func replayLog() {
        guard let eventsURL,
              let raw = try? String(contentsOf: eventsURL, encoding: .utf8)
        else { return }
        let decoder = JSONDecoder()
        let now = Date().timeIntervalSince1970
        for line in raw.split(separator: "\n").suffix(Self.maxReplayEvents) {
            guard let event = try? decoder.decode(Event.self, from: Data(line.utf8))
            else { continue }
            let age = max(0, now - event.ts)
            let weight = max(Self.replayWeightFloor,
                             exp2f(Float(-age / Self.replayHalfLife)))
            train(target: event.target, entries: event.entries,
                  chosen: event.chosen, weight: weight)
        }
        if eventCount > 0 {
            csLog("window ranker replayed \(eventCount) events")
        }
    }
}
