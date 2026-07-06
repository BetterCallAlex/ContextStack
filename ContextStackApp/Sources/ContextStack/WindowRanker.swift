import Foundation

/// Learns which *window* the user will pick, given the paste target and each
/// entry's app, kind, recency rank, selection and copy state. Same
/// [PointwiseSoftmaxModel] substrate as the action head — here candidates
/// are the presented entries themselves, sharing one weight vector.
///
/// Used to move the picker's preselection highlight, never to reorder the
/// list: recency order is muscle memory, the highlight is the prediction.
final class WindowRanker {
    static let shared = WindowRanker(eventsURL: EventLogFile(filename: "window-events.jsonl").url)

    struct EntryFeatures: Codable {
        let src: String
        let kind: String
        let sel: Bool
        /// User manually copied from this app recently (clipboard observer,
        /// opt-in). Optional so older logs replay unchanged.
        var mcopy: Bool? = nil
        /// Session-topic similarity bucket ("high"/"mid"/"low"), content
        /// learning opt-in. Optional for old-log compatibility.
        var topic: String? = nil
    }

    private struct Event: Codable {
        let v: Int
        let ts: Double
        let target: String
        let entries: [EntryFeatures]
        let chosen: Int
    }

    private static let dims = 4096

    private var model = PointwiseSoftmaxModel(weightCount: dims)
    private(set) var eventCount = 0
    private let log: EventLogFile

    init(eventsURL: URL?) {
        log = EventLogFile(url: eventsURL)
        if eventsURL != nil { replayLog() }
    }

    // -------------------------------------------------------------- model

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
        if let topic = entry.topic {
            names.append("topic:\(topic)")
            names.append("topic+tgt:\(topic)|\(target)")
        }
        return names.map { LearningCore.hashIndex($0, dims: dims) }
    }

    private static func candidates(target: String,
                                   entries: [EntryFeatures]) -> [[Int]] {
        entries.enumerated().map { features(target: target, entry: $1, rank: $0) }
    }

    /// Softmax over the presented entries, in presentation (recency) order.
    func probabilities(target: String, entries: [EntryFeatures]) -> [Float] {
        model.probabilities(candidates: Self.candidates(target: target, entries: entries))
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
        model.train(candidates: Self.candidates(target: target, entries: entries),
                    chosen: chosen, weight: weight)
        eventCount += 1
    }

    // ------------------------------------------------------------ recording

    func record(target: String, entries: [EntryFeatures], chosen: Int) {
        log.append(Event(v: 1, ts: Date().timeIntervalSince1970,
                         target: target, entries: entries, chosen: chosen))
        train(target: target, entries: entries, chosen: chosen, weight: 1)
    }

    private func replayLog() {
        let decoder = JSONDecoder()
        let now = Date().timeIntervalSince1970
        for line in log.replayLines() {
            guard let event = try? decoder.decode(Event.self, from: line) else { continue }
            train(target: event.target, entries: event.entries,
                  chosen: event.chosen,
                  weight: LearningCore.replayWeight(ageSeconds: now - event.ts))
        }
        if eventCount > 0 {
            csLog("window ranker replayed \(eventCount) events")
        }
    }
}
