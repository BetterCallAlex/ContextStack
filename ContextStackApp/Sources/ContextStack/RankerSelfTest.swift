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
                                          hourBucket: 2),
                     presented: documentActions, chosen: .atReference),
            Scenario(name: "Zed projectB → screenshot",
                     context: RankContext(targetBundleID: claude, sourceBundleID: zed,
                                          kind: "document",
                                          titleTokens: ["projectb", "app", "tsx"],
                                          hourBucket: 2),
                     presented: documentActions, chosen: .screenshotClipboard),
            Scenario(name: "Safari → Claude: page text",
                     context: RankContext(targetBundleID: claude, sourceBundleID: safari,
                                          kind: "browser tab",
                                          titleTokens: ["anthropic", "docs"],
                                          hourBucket: 2),
                     presented: browserActions, chosen: .pageText),
            Scenario(name: "Safari → terminal: link",
                     context: RankContext(targetBundleID: terminal, sourceBundleID: safari,
                                          kind: "browser tab",
                                          titleTokens: ["anthropic", "docs"],
                                          hourBucket: 2),
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

        // Cold start: an unseen Zed project should back off to Zed-level
        // knowledge, not to noise.
        let fresh = RankContext(targetBundleID: claude, sourceBundleID: zed,
                                kind: "document",
                                titleTokens: ["projectc", "lib", "py"],
                                hourBucket: 2)
        let probs = ranker.probabilities(context: fresh, presented: documentActions)
        let top = documentActions.max { (probs[$0] ?? 0) < (probs[$1] ?? 0) }!
        let plausible: Set<ActionID> = [.atReference, .screenshotClipboard]
        print("cold-start unseen Zed project → \(top.rawValue) "
              + (plausible.contains(top) ? "(app-level backoff ok)" : "(UNEXPECTED)"))

        let pass = accuracy >= 0.9 && plausible.contains(top)
        print(pass ? "PASS" : "FAIL")
        exit(pass ? 0 : 1)
    }
}
