import Foundation

/// `ContextStack --ranker-selftest` — trains an in-memory ranker on a
/// synthetic usage pattern and reports prequential (predict-then-train)
/// accuracy. No permissions, no GUI; exercises exactly the code path the
/// action chooser uses.
enum RankerSelfTest {
    private static let documentActions: [ActionID] = [
        .filePath, .atReference, .fileContents,
        .screenshotClipboard, .screenshotPath, .windowText, .titleLine,
    ]
    private static let browserActions: [ActionID] = [
        .pageText, .linkMarkdown, .fullHTML,
        .screenshotClipboard, .screenshotPath, .titleLine,
    ]

    private struct Scenario {
        let name: String
        let context: RankContext
        let presented: [ActionID]
        let chosen: ActionID
    }

    static func run() {
        let claude = "com.anthropic.claudefordesktop"
        let terminal = "com.googlecode.iterm2"
        let zed = "dev.zed.Zed"
        let safari = "com.apple.Safari"

        // The user's example: same app (Zed), different project → different
        // preferred action. Plus a target-dependent browser pattern.
        let scenarios = [
            Scenario(name: "Zed projectA → @-reference",
                     context: RankContext(targetBundleID: claude, sourceBundleID: zed,
                                          kind: "document",
                                          titleTokens: ["projecta", "main", "rs"],
                                          hourBucket: 2, hasSelection: false),
                     presented: documentActions, chosen: .atReference),
            Scenario(name: "Zed projectB → screenshot",
                     context: RankContext(targetBundleID: claude, sourceBundleID: zed,
                                          kind: "document",
                                          titleTokens: ["projectb", "app", "tsx"],
                                          hourBucket: 2, hasSelection: false),
                     presented: documentActions, chosen: .screenshotClipboard),
            Scenario(name: "Safari → Claude: page text",
                     context: RankContext(targetBundleID: claude, sourceBundleID: safari,
                                          kind: "browser tab",
                                          titleTokens: ["anthropic", "docs"],
                                          hourBucket: 2, hasSelection: false),
                     presented: browserActions, chosen: .pageText),
            Scenario(name: "Safari → terminal: link",
                     context: RankContext(targetBundleID: terminal, sourceBundleID: safari,
                                          kind: "browser tab",
                                          titleTokens: ["anthropic", "docs"],
                                          hourBucket: 2, hasSelection: false),
                     presented: browserActions, chosen: .linkMarkdown),
        ]

        let ranker = ActionRanker(eventsURL: nil)
        let rounds = 40
        var correctLate = 0
        var totalLate = 0

        for round in 0..<rounds {
            for s in scenarios {
                let probs = ranker.probabilities(context: s.context, presented: s.presented)
                let predicted = s.presented.max { (probs[$0] ?? 0) < (probs[$1] ?? 0) }!
                if round >= rounds / 2 {
                    totalLate += 1
                    if predicted == s.chosen { correctLate += 1 }
                }
                ranker.record(context: s.context, presented: s.presented, chosen: s.chosen)
            }
        }

        print("ranker selftest: \(scenarios.count) interleaved scenarios × \(rounds) rounds")
        let accuracy = Double(correctLate) / Double(totalLate)
        print(String(format: "prequential top-1 accuracy (late half): %.1f%%", accuracy * 100))

        for s in scenarios {
            let probs = ranker.probabilities(context: s.context, presented: s.presented)
            let top = s.presented.max { (probs[$0] ?? 0) < (probs[$1] ?? 0) }!
            let mark = top == s.chosen ? "ok " : "MISS"
            print(String(format: "  %@  %-32@ → %@ (p=%.2f)",
                         mark, s.name as NSString, top.rawValue,
                         probs[top] ?? 0))
        }

        // Stickiness: identical context, but the preferred action flips in
        // blocks (debugging burst vs. wiring burst). Static features see the
        // same context both ways — only the previous-action sequence
        // features can predict block continuation.
        let burstRanker = ActionRanker(eventsURL: nil)
        let burstCtx = RankContext(targetBundleID: claude, sourceBundleID: zed,
                                   kind: "document",
                                   titleTokens: ["projecta", "main", "rs"],
                                   hourBucket: 2, hasSelection: false)
        var burstCorrect = 0
        var burstTotal = 0
        let blockChoices: [ActionID] = [.atReference, .screenshotClipboard]
        for block in 0..<12 {
            let chosen = blockChoices[block % 2]
            for position in 0..<6 {
                let probs = burstRanker.probabilities(context: burstCtx,
                                                      presented: documentActions)
                let predicted = documentActions.max {
                    (probs[$0] ?? 0) < (probs[$1] ?? 0)
                }!
                // Score only continuation picks (not the unknowable block
                // flip) once warmed up.
                if block >= 4, position >= 1 {
                    burstTotal += 1
                    if predicted == chosen { burstCorrect += 1 }
                }
                burstRanker.record(context: burstCtx,
                                   presented: documentActions, chosen: chosen)
            }
        }
        let burstAccuracy = Double(burstCorrect) / Double(burstTotal)
        print(String(format: "burst continuation accuracy (identical context): %.1f%%",
                     burstAccuracy * 100))

        // Cold start: an unseen Zed project should back off to Zed-level
        // knowledge, not to noise.
        let fresh = RankContext(targetBundleID: claude, sourceBundleID: zed,
                                kind: "document",
                                titleTokens: ["projectc", "lib", "py"],
                                hourBucket: 2, hasSelection: false)
        let probs = ranker.probabilities(context: fresh, presented: documentActions)
        let top = documentActions.max { (probs[$0] ?? 0) < (probs[$1] ?? 0) }!
        let plausible: Set<ActionID> = [.atReference, .screenshotClipboard]
        print("cold-start unseen Zed project → \(top.rawValue) "
              + (plausible.contains(top) ? "(app-level backoff ok)" : "(UNEXPECTED)"))

        // Selection as a learned feature: identical context and identical
        // presented set; the pick depends only on whether a selection exists.
        // The sel pattern is deliberately non-alternating so the sequence
        // features can't stand in for it.
        let selRanker = ActionRanker(eventsURL: nil)
        let selPattern = [true, false, false, true, false, true, true, false]
        var selCorrect = 0
        var selTotal = 0
        for round in 0..<12 {
            for sel in selPattern {
                let ctx = RankContext(targetBundleID: claude, sourceBundleID: zed,
                                      kind: "document",
                                      titleTokens: ["projecta", "main", "rs"],
                                      hourBucket: 2, hasSelection: sel)
                let chosen: ActionID = sel ? .fileContents : .screenshotClipboard
                let probs = selRanker.probabilities(context: ctx,
                                                    presented: documentActions)
                let predicted = documentActions.max {
                    (probs[$0] ?? 0) < (probs[$1] ?? 0)
                }!
                if round >= 6 {
                    selTotal += 1
                    if predicted == chosen { selCorrect += 1 }
                }
                selRanker.record(context: ctx, presented: documentActions,
                                 chosen: chosen)
            }
        }
        let selAccuracy = Double(selCorrect) / Double(selTotal)
        print(String(format: "selection-feature accuracy (identical context): %.1f%%",
                     selAccuracy * 100))

        // Window ranker: recency order fixed; the user picks the Zed window
        // when it has a selection, the most-recent Safari window otherwise.
        let winRanker = WindowRanker(eventsURL: nil)
        func winEntries(zedSel: Bool) -> [WindowRanker.EntryFeatures] {
            [WindowRanker.EntryFeatures(src: safari, kind: "browser tab", sel: false),
             WindowRanker.EntryFeatures(src: zed, kind: "document", sel: zedSel),
             WindowRanker.EntryFeatures(src: terminal, kind: "window", sel: false)]
        }
        var winCorrect = 0
        var winTotal = 0
        var earlyPrediction: Int?
        for round in 0..<40 {
            let zedSel = selPattern[round % selPattern.count]
            let entries = winEntries(zedSel: zedSel)
            let chosen = zedSel ? 1 : 0
            if round == 5 {
                earlyPrediction = winRanker.predictedIndex(target: claude,
                                                           entries: entries)
            }
            if round >= 20 {
                let probs = winRanker.probabilities(target: claude, entries: entries)
                let predicted = probs.indices.max { probs[$0] < probs[$1] }!
                winTotal += 1
                if predicted == chosen { winCorrect += 1 }
            }
            winRanker.record(target: claude, entries: entries, chosen: chosen)
        }
        let winAccuracy = Double(winCorrect) / Double(winTotal)
        print(String(format: "window-ranker accuracy (selection-driven): %.1f%%",
                     winAccuracy * 100))
        print("window-ranker holds back before 20 events: "
              + (earlyPrediction == nil ? "ok" : "UNEXPECTED"))

        let pass = accuracy >= 0.9 && burstAccuracy >= 0.75 && plausible.contains(top)
            && selAccuracy >= 0.8 && winAccuracy >= 0.8 && earlyPrediction == nil
        print(pass ? "PASS" : "FAIL")
        exit(pass ? 0 : 1)
    }
}
