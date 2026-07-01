import AppKit

/// Canonical identity of every capture action, used for learning.
enum ActionID: String, CaseIterable, Codable {
    case pageText, linkMarkdown, fullHTML
    case filePath, atReference, fileContents
    case screenshotClipboard, screenshotPath
    case windowText, titleLine
}

/// Everything the ranker is allowed to know about one picker invocation.
struct RankContext {
    /// Frontmost app when the hotkey was pressed — the paste target.
    let targetBundleID: String
    let sourceBundleID: String
    /// "browser tab" | "document" | "window" (PickerFlow.kindLabel).
    let kind: String
    /// Tokens from the source window title — carries project/site identity.
    let titleTokens: [String]
    /// 0–3: night / morning / afternoon / evening.
    let hourBucket: Int

    static func hourBucket(for date: Date = Date()) -> Int {
        Calendar.current.component(.hour, from: date) / 6
    }
}

/// Learns which capture action the user picks in which context, to put the
/// most likely one on top of the action chooser (Enter-Enter gets smarter).
///
/// Model: a single-layer softmax network (online multinomial logistic
/// regression) over hashed sparse features, trained with one SGD step per
/// observed pick. The softmax is masked to the actions actually presented
/// for that entry type. The global → per-app → per-project hierarchy is
/// encoded in the features themselves:
///
///   bias                        → global trend
///   src / tgt / kind            → per-app trends
///   tgt×src, tgt×kind, src×kind → pairings ("into Claude paste images,
///                                 into the terminal paste @paths")
///   tok, src×tok                → within-app context (project names, sites)
///   hour bucket                 → mild time-of-day signal
///
/// Unseen contexts back off to whatever coarser features have learned —
/// cold start degrades smoothly to the app-level and global answer.
///
/// The append-only event log is the source of truth; weights are a cache
/// rebuilt by replaying the log at launch, so the feature set can change
/// between versions without losing data.
final class ActionRanker {
    static let shared = ActionRanker(eventsURL: defaultEventsURL())

    private static let dims = 4096
    private static let learningRate: Float = 0.15
    private static let maxReplayEvents = 5000
    private static let classIndex: [ActionID: Int] = Dictionary(
        uniqueKeysWithValues: ActionID.allCases.enumerated().map { ($1, $0) })

    /// Flat [class][dim] weight matrix.
    private var weights = [Float](repeating: 0,
                                  count: ActionID.allCases.count * dims)
    private(set) var eventCount = 0
    private var sourceCounts: [String: Int] = [:]
    private let eventsURL: URL?

    struct Event: Codable {
        let v: Int
        let ts: Double
        let target: String
        let source: String
        let kind: String
        let tokens: [String]
        let hour: Int
        let presented: [String]
        let chosen: String
    }

    /// Pass nil for an in-memory ranker (tests).
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
        return dir.appendingPathComponent("action-events.jsonl")
    }

    // ------------------------------------------------------------- features

    static func tokenize(_ title: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for ch in title.lowercased() {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else {
                if current.count >= 2 { tokens.append(current) }
                current = ""
            }
        }
        if current.count >= 2 { tokens.append(current) }
        var seen = Set<String>()
        var out: [String] = []
        for t in tokens where seen.insert(t).inserted {
            out.append(t)
            if out.count == 12 { break }
        }
        return out
    }

    /// FNV-1a — Swift's Hasher is seeded per process, so it can't be used
    /// for weights that must line up across replays.
    private static func hashIndex(_ name: String) -> Int {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in name.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return Int(h % UInt64(dims))
    }

    private static func features(_ c: RankContext) -> [Int] {
        var names = [
            "bias",
            "tgt:\(c.targetBundleID)",
            "src:\(c.sourceBundleID)",
            "kind:\(c.kind)",
            "tgt+src:\(c.targetBundleID)|\(c.sourceBundleID)",
            "tgt+kind:\(c.targetBundleID)|\(c.kind)",
            "src+kind:\(c.sourceBundleID)|\(c.kind)",
            "hour:\(c.hourBucket)",
        ]
        for t in c.titleTokens {
            names.append("tok:\(t)")
            names.append("src+tok:\(c.sourceBundleID)|\(t)")
        }
        return names.map(hashIndex)
    }

    // ---------------------------------------------------------------- model

    private func score(class c: Int, features: [Int]) -> Float {
        var s: Float = 0
        let base = c * Self.dims
        for f in features { s += weights[base + f] }
        return s
    }

    /// Softmax over the presented actions only.
    func probabilities(context: RankContext,
                       presented: [ActionID]) -> [ActionID: Float] {
        let feats = Self.features(context)
        let raw = presented.map { score(class: Self.classIndex[$0]!, features: feats) }
        let maxRaw = raw.max() ?? 0
        let exps = raw.map { expf($0 - maxRaw) }
        let sum = max(exps.reduce(0, +), .leastNormalMagnitude)
        var out: [ActionID: Float] = [:]
        for (i, a) in presented.enumerated() { out[a] = exps[i] / sum }
        return out
    }

    /// One SGD step of masked-softmax cross-entropy.
    private func train(context: RankContext, presented: [ActionID], chosen: ActionID) {
        guard presented.contains(chosen) else { return }
        let feats = Self.features(context)
        let probs = probabilities(context: context, presented: presented)
        for a in presented {
            let gradient = probs[a]! - (a == chosen ? 1 : 0)
            let step = Self.learningRate * gradient
            let base = Self.classIndex[a]! * Self.dims
            for f in feats { weights[base + f] -= step }
        }
        eventCount += 1
        sourceCounts[context.sourceBundleID, default: 0] += 1
    }

    /// How many picks the model has seen from this source app.
    func samples(forSource bundleID: String) -> Int {
        sourceCounts[bundleID] ?? 0
    }

    // ------------------------------------------------------------ recording

    /// Log the user's pick and update the model. Called for every completed
    /// capture, whether or not smart ranking is currently enabled.
    func record(context: RankContext, presented: [ActionID], chosen: ActionID) {
        let event = Event(v: 1,
                          ts: Date().timeIntervalSince1970,
                          target: context.targetBundleID,
                          source: context.sourceBundleID,
                          kind: context.kind,
                          tokens: context.titleTokens,
                          hour: context.hourBucket,
                          presented: presented.map(\.rawValue),
                          chosen: chosen.rawValue)
        appendToLog(event)
        train(context: context, presented: presented, chosen: chosen)
    }

    private func appendToLog(_ event: Event) {
        guard let eventsURL, let data = try? JSONEncoder().encode(event) else { return }
        if !FileManager.default.fileExists(atPath: eventsURL.path) {
            FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: eventsURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }

    private func replayLog() {
        guard let eventsURL,
              let raw = try? String(contentsOf: eventsURL, encoding: .utf8)
        else { return }
        let decoder = JSONDecoder()
        let lines = raw.split(separator: "\n").suffix(Self.maxReplayEvents)
        for line in lines {
            guard let event = try? decoder.decode(Event.self, from: Data(line.utf8)),
                  let chosen = ActionID(rawValue: event.chosen) else { continue }
            let context = RankContext(targetBundleID: event.target,
                                      sourceBundleID: event.source,
                                      kind: event.kind,
                                      titleTokens: event.tokens,
                                      hourBucket: event.hour)
            let presented = event.presented.compactMap(ActionID.init(rawValue:))
            train(context: context, presented: presented, chosen: chosen)
        }
        if eventCount > 0 {
            csLog("ranker replayed \(eventCount) events")
        }
    }
}
