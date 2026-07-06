import AppKit

/// Canonical identity of every capture action, used for learning.
enum ActionID: String, CaseIterable, Codable {
    case pageText, linkMarkdown, fullHTML
    case filePath, atReference, fileContents
    case screenshotClipboard, screenshotPath
    case windowText, titleLine
    // Appended cases only — the position in allCases is the class index of
    // the weight matrix, so existing learned weights must keep their slots.
    case selectedText, visibleExcerpt
    case screenshotOCR
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
    /// The source window had a text selection. Fed as a learned feature —
    /// some users select to paste, others select to read; the model measures
    /// which, per app.
    let hasSelection: Bool

    static func hourBucket(for date: Date = Date()) -> Int {
        Calendar.current.component(.hour, from: date) / 6
    }
}

/// Learns which capture action the user picks in which context, to put the
/// most likely one on top of the action chooser (Enter-Enter gets smarter).
///
/// The model is a [PointwiseSoftmaxModel] over hashed features; each action
/// class owns a row of the weight matrix, expressed as per-candidate feature
/// offsets. The global → per-app → per-project hierarchy is encoded in the
/// features themselves:
///
///   bias                        → global trend
///   src / tgt / kind            → per-app trends
///   tgt×src, tgt×kind, src×kind → pairings ("into Claude paste images,
///                                 into the terminal paste @paths")
///   tok, src×tok                → within-app context (project names, sites)
///   sel, sel×src, sel×tgt       → selection as a learned signal
///   hour bucket                 → mild time-of-day signal
///
/// Sequence features (previous pick in-session / per-source, prev×kind
/// bigram) ride on top; pastes cluster in bursts. Re-picking the same
/// window within seconds with a different action relabels the previous
/// pick (correction). The event log is the source of truth; weights are a
/// cache rebuilt by recency-weighted replay at launch.
final class ActionRanker {
    static let shared = ActionRanker(eventsURL: EventLogFile(filename: "action-events.jsonl").url)

    private static let dims = 4096
    /// "Session" window for the global previous-action feature.
    private static let sessionGap: TimeInterval = 30 * 60
    /// Window for the per-source previous-action feature.
    private static let sourceGap: TimeInterval = 6 * 3600
    /// Re-picking the same window within this window with a different action
    /// means the first pick was a mistake — relabel it.
    private static let correctionGap: TimeInterval = 30
    private static let correctionWeight: Float = 0.7
    private static let classIndex: [ActionID: Int] = Dictionary(
        uniqueKeysWithValues: ActionID.allCases.enumerated().map { ($1, $0) })

    private var model = PointwiseSoftmaxModel(
        weightCount: ActionID.allCases.count * dims)
    private(set) var eventCount = 0
    private var sourceCounts: [String: Int] = [:]
    private var lastGlobal: (action: ActionID, time: Date)?
    private var lastPerSource: [String: (action: ActionID, time: Date)] = [:]
    /// For correction detection: the previous pick in full, including the
    /// exact candidate feature sets it trained on — the relabel must touch
    /// the same weights, and the sequence state has moved on by then.
    private var lastPick: (context: RankContext, presented: [ActionID],
                           chosen: ActionID, time: Date, candidates: [[Int]])?
    private let log: EventLogFile

    struct Event: Codable {
        let v: Int
        let ts: Double
        let target: String
        let source: String
        let kind: String
        let tokens: [String]
        let hour: Int
        /// Optional so pre-selection-feature logs replay unchanged.
        let sel: Bool?
        let presented: [String]
        let chosen: String
    }

    /// Pass nil for an in-memory ranker (tests).
    init(eventsURL: URL?) {
        log = EventLogFile(url: eventsURL)
        if eventsURL != nil { replayLog() }
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

    private static func hashIndex(_ name: String) -> Int {
        LearningCore.hashIndex(name, dims: dims)
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
        if c.hasSelection {
            names.append("sel:1")
            names.append("sel+src:\(c.sourceBundleID)")
            names.append("sel+tgt:\(c.targetBundleID)")
        }
        for t in c.titleTokens {
            names.append("tok:\(t)")
            names.append("src+tok:\(c.sourceBundleID)|\(t)")
        }
        return names.map(hashIndex)
    }

    /// Sequence features from the tracked previous-pick state.
    private func sequenceFeatures(_ c: RankContext, at time: Date) -> [Int] {
        var names: [String] = []
        if let g = lastGlobal, time.timeIntervalSince(g.time) < Self.sessionGap,
           time >= g.time {
            names.append("prevG:\(g.action.rawValue)")
            names.append("prevG+kind:\(g.action.rawValue)|\(c.kind)")
        }
        if let s = lastPerSource[c.sourceBundleID],
           time.timeIntervalSince(s.time) < Self.sourceGap, time >= s.time {
            names.append("prevSrc:\(s.action.rawValue)|\(c.sourceBundleID)")
        }
        return names.map(Self.hashIndex)
    }

    /// One candidate feature set per presented action: the shared context
    /// features offset into that action's row of the weight matrix.
    private func candidates(_ c: RankContext, presented: [ActionID],
                            at time: Date) -> [[Int]] {
        let feats = Self.features(c) + sequenceFeatures(c, at: time)
        return presented.map { action in
            let base = Self.classIndex[action]! * Self.dims
            return feats.map { base + $0 }
        }
    }

    // ---------------------------------------------------------------- model

    /// Softmax over the presented actions only.
    func probabilities(context: RankContext, presented: [ActionID],
                       at time: Date = Date()) -> [ActionID: Float] {
        let probs = model.probabilities(
            candidates: candidates(context, presented: presented, at: time))
        return Dictionary(uniqueKeysWithValues: zip(presented, probs))
    }

    /// One SGD step toward the pick, then advance the sequence state and
    /// apply a correction relabel when this pick contradicts the previous
    /// one on the same window seconds earlier.
    private func train(context: RankContext, presented: [ActionID],
                       chosen: ActionID, at time: Date, weight: Float) {
        guard let chosenIndex = presented.firstIndex(of: chosen) else { return }
        let cands = candidates(context, presented: presented, at: time)
        model.train(candidates: cands, chosen: chosenIndex, weight: weight)
        eventCount += 1
        sourceCounts[context.sourceBundleID, default: 0] += 1
        lastGlobal = (chosen, time)
        lastPerSource[context.sourceBundleID] = (chosen, time)

        // Correction: same window, same target and selection state, seconds
        // later, different action — the previous pick was wrong. Relabel it
        // with the corrected action (reduced weight; derived purely from
        // event order, so replay applies the same corrections).
        if let prev = lastPick,
           time.timeIntervalSince(prev.time) < Self.correctionGap,
           prev.context.sourceBundleID == context.sourceBundleID,
           prev.context.targetBundleID == context.targetBundleID,
           prev.context.titleTokens == context.titleTokens,
           prev.context.hasSelection == context.hasSelection,
           prev.chosen != chosen,
           let correctedIndex = prev.presented.firstIndex(of: chosen) {
            model.train(candidates: prev.candidates, chosen: correctedIndex,
                        weight: Self.correctionWeight)
        }
        lastPick = (context, presented, chosen, time, cands)
    }

    /// How many picks the model has seen from this source app.
    func samples(forSource bundleID: String) -> Int {
        sourceCounts[bundleID] ?? 0
    }

    // ------------------------------------------------------------ recording

    /// Train without logging, with a controllable clock — offline evaluation
    /// (--eval-log) and timing-sensitive selftests.
    func recordForEvaluation(context: RankContext, presented: [ActionID],
                             chosen: ActionID, at time: Date) {
        train(context: context, presented: presented, chosen: chosen,
              at: time, weight: 1)
    }

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
                          sel: context.hasSelection,
                          presented: presented.map(\.rawValue),
                          chosen: chosen.rawValue)
        log.append(event)
        train(context: context, presented: presented, chosen: chosen,
              at: Date(), weight: 1)
    }

    private func replayLog() {
        let decoder = JSONDecoder()
        let now = Date().timeIntervalSince1970
        for line in log.replayLines() {
            guard let event = try? decoder.decode(Event.self, from: line),
                  let chosen = ActionID(rawValue: event.chosen) else { continue }
            let context = RankContext(targetBundleID: event.target,
                                      sourceBundleID: event.source,
                                      kind: event.kind,
                                      titleTokens: event.tokens,
                                      hourBucket: event.hour,
                                      hasSelection: event.sel ?? false)
            let presented = event.presented.compactMap(ActionID.init(rawValue:))
            train(context: context, presented: presented, chosen: chosen,
                  at: Date(timeIntervalSince1970: event.ts),
                  weight: LearningCore.replayWeight(ageSeconds: now - event.ts))
        }
        if eventCount > 0 {
            csLog("ranker replayed \(eventCount) events")
        }
    }
}
