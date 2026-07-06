import AppKit
import ApplicationServices

/// Every `--flag` selftest / diagnostic mode on the binary, dispatched at
/// startup before AppKit boots. Each mode exits the process. Live modes
/// (AX / Screen Recording / Automation) must run via
/// `open -n -W /Applications/ContextStack.app --args <flag> …` so TCC
/// grants apply; parser/fixture selftests run fine from the build dir.
@MainActor
enum CLIModes {
    // ------------------------------------------------------------- helpers

    private static var args: [String] { CommandLine.arguments }

    private static func value(after flag: String, offset: Int = 1) -> String? {
        guard let i = args.firstIndex(of: flag), args.count > i + offset
        else { return nil }
        return args[i + offset]
    }

    /// Entry for a running app's focused window (the standard live-test rig).
    private static func makeEntry(query: String) -> HistoryEntry? {
        let q = query.lowercased()
        guard let target = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").lowercased().contains(q)
        }), let win = AX.element(AX.application(target.processIdentifier),
                                 kAXFocusedWindowAttribute as String) else { return nil }
        return HistoryEntry(axWindow: win, pid: target.processIdentifier,
                            appName: target.localizedName ?? "?",
                            bundleID: target.bundleIdentifier ?? "",
                            title: AX.string(win, kAXTitleAttribute as String) ?? "")
    }

    /// Pump the main run loop until the condition holds or the timeout hits.
    @discardableResult
    private static func pump(timeout: TimeInterval,
                             until condition: () -> Bool = { false }) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private static func writeOut(_ path: String, _ text: String) {
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// PASS/FAIL check accumulator shared by the fixture selftests.
    private final class Checker {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            if !ok { failures += 1 }
            print("  \(ok ? "ok " : "MISS") \(name)")
        }
        func finish() -> Never {
            print(failures == 0 ? "PASS" : "FAIL (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
    }

    // ------------------------------------------------------------ dispatch

    static func runIfRequested() {
        if args.contains("--ranker-selftest") { RankerSelfTest.run() }
        if args.contains("--doc-selftest") { DocSelfTest.run() }
        if args.contains("--remote-selftest") { RemoteSelfTest.run() }
        if let dir = value(after: "--render-icon") {
            IconKit.renderIconset(to: URL(fileURLWithPath: dir))
            exit(0)
        }
        if args.contains("--topic-test") { topicTest() }
        if args.contains("--salience-test") { salienceTest() }
        if args.contains("--summarize-test") { summarizeTest() }
        if args.contains("--eval-log") { evalLog() }
        if let app1 = value(after: "--stack-test"),
           let app2 = value(after: "--stack-test", offset: 2),
           let out = value(after: "--stack-test", offset: 3) {
            stackTest(app1: app1, app2: app2, outPath: out)
        }
        if args.contains("--clipboard-test") { clipboardTest() }
        if let app = value(after: "--prefetch-test"),
           let out = value(after: "--prefetch-test", offset: 2) {
            prefetchTest(appQuery: app, outPath: out)
        }
        if args.contains("--archive-test") { archiveTest() }
        if let spec = value(after: "--hotkey-test") { hotkeyTest(spec: spec) }
        if let app = value(after: "--selection-test"),
           let out = value(after: "--selection-test", offset: 2) {
            selectionTest(appQuery: app, outPath: out)
        }
        if let app = value(after: "--perf-test"),
           let out = value(after: "--perf-test", offset: 2) {
            PerfTest.run(appQuery: app, outPath: out)
        }
        if let app = value(after: "--diag"),
           let out = value(after: "--diag", offset: 2) {
            Diagnostics.run(appQuery: app, outPath: out)
        }
        if let host = value(after: "--remote-find-test"),
           let filename = value(after: "--remote-find-test", offset: 2) {
            remoteFindTest(host: host, filename: filename,
                           root: value(after: "--remote-find-test", offset: 3) ?? ".")
        }
        if let path = value(after: "--remote-test") { remoteTest(path: path) }
        if let app = value(after: "--ocr-test"),
           let out = value(after: "--ocr-test", offset: 2) {
            ocrTest(appQuery: app, outPath: out)
        }
        if let app = value(after: "--shot-test") { shotTest(appQuery: app) }
        if let dir = value(after: "--ui-shots") { UIShots.requestedDir = dir }
    }

    // ------------------------------------------------------------- modes

    /// Live check of the on-device LLM tier: availability, a real
    /// summarization round trip, and a tagging round trip. Exits 0 with a
    /// note when Apple Intelligence isn't available — that's a machine
    /// state, not a code failure.
    private static func summarizeTest() -> Never {
        print("FoundationModels: \(LocalLLM.availabilityNote)")
        guard LocalLLM.isAvailable else {
            print("SKIP (LLM tier hides itself when unavailable)")
            exit(0)
        }
        let stack = """
        # Context stack — 2 items (test)

        ## 1 · Terminal — build log
        Source: terminal
        swift build failed
        error: cannot find 'SystemLanguageModel' in scope
        note: add an availability guard for macOS 26

        ---

        ## 2 · Zed — LocalLLM.swift
        Source: /tmp/LocalLLM.swift
        enum LocalLLM { static var isAvailable: Bool { ... } }
        // guards FoundationModels behind canImport and #available
        """
        var summary: String?
        var done = false
        LocalLLM.summarizeStack(stack) { summary = $0; done = true }
        pump(timeout: 60, until: { done })
        if let summary {
            print("summary chars=\(summary.count)")
            print(summary.split(separator: "\n").prefix(6).joined(separator: "\n"))
        } else {
            print("summarization returned nil")
            exit(1)
        }
        // Tagging round trip (respond directly — tagCapture gates on the
        // contentLearning toggle, which we don't want to flip here).
        var tags: String?
        done = false
        LocalLLM.respond(
            instructions: "Reply with ONLY comma-separated tags from: "
                + LocalLLM.tagVocabulary.joined(separator: ", "),
            prompt: "error: linker command failed\nUndefined symbols for arm64") {
            tags = $0
            done = true
        }
        pump(timeout: 30, until: { done })
        print("tag reply: \(tags ?? "nil")")
        print(summary != nil ? "PASS" : "FAIL")
        exit(0)
    }

    /// Salience scoring fixtures: chunking, heuristics, git boost, budget,
    /// labels and the adaptive-budget feedback loop.
    private static func salienceTest() -> Never {
        let c = Checker()
        let noise = (1...30).map { "filler line \($0) with nothing special" }
            .joined(separator: "\n")
        let text = """
        intro line one
        intro line two

        \(noise)

        func compute() {
            return broken
        }
        ERROR: Traceback (most recent call last)
          ValueError: shapes do not align

        more filler here
        and more

        // TODO: fix the alignment issue
        """

        let chunks = SalienceModel.chunks(of: text)
        c.check("chunking splits on blank lines", chunks.count >= 5)
        c.check("long block split at 20 lines",
                chunks.allSatisfy { $0.endLine - $0.startLine < 20 })

        c.check("error text outranks filler",
                SalienceModel.heuristicScore("ERROR: Traceback follows")
                > SalienceModel.heuristicScore("filler line"))
        c.check("todo scores between",
                SalienceModel.heuristicScore("// TODO: thing") > 0)

        let excerpt = SalienceModel.relevantExcerpt(
            from: text, budgetLines: 10, topic: nil, changed: [])
        c.check("error chunk included", excerpt.contains("Traceback"))
        c.check("filler excluded at tight budget", !excerpt.contains("filler line 15"))
        c.check("line labels present", excerpt.contains("[lines "))
        c.check("gap marker present", excerpt.contains("⋯"))

        // Isolated git boost: uniform filler, one changed line deep inside.
        let uniform = (1...60).map { "plain line \($0)" }.joined(separator: "\n\n")
        let changedBoost = SalienceModel.relevantExcerpt(
            from: uniform, budgetLines: 3, topic: nil, changed: [79]) // "plain line 40"
        c.check("git-changed chunk wins at tiny budget",
                changedBoost.contains("plain line 40"))

        let plain = SalienceModel.relevantExcerpt(
            from: "just one line", budgetLines: 10, topic: nil, changed: [])
        c.check("no-signal file falls back to content", plain.contains("just one line"))

        // Adaptive budget: widen on full-after-excerpt, tighten on accept.
        UserDefaults.standard.removeObject(forKey: "excerptBudgetLines")
        let start = SalienceModel.budgetLines
        SalienceModel.noteExcerptDelivered(signature: "sig")
        SalienceModel.noteFullCapture(signature: "sig")
        let widened = SalienceModel.budgetLines
        c.check("budget widens after full-recapture (\(start)→\(widened))",
                widened > start)
        SalienceModel.noteExcerptDelivered(signature: "sig2")
        c.check("budget tightens on accepted excerpt",
                SalienceModel.budgetLines < widened)
        SalienceModel.noteFullCapture(signature: "other-sig")
        c.check("unrelated full capture doesn't widen",
                SalienceModel.budgetLines < widened)
        UserDefaults.standard.removeObject(forKey: "excerptBudgetLines")
        c.finish()
    }

    /// Topic embedding sanity: availability, semantic separation, and the
    /// archive → topic vector → bucket path end to end.
    private static func topicTest() -> Never {
        let c = Checker()
        let wasOn = Config.contentLearning
        Config.contentLearning = true
        func restoreAndFinish() -> Never {
            Config.contentLearning = wasOn
            c.finish()
        }
        c.check("NLEmbedding available", TopicModel.available)
        guard TopicModel.available else { restoreAndFinish() }

        let v1 = TopicModel.vector(for: "python dataframe pandas notebook bot detection analysis")
        let v2 = TopicModel.vector(for: "polars dataframe python code for the detection notebook")
        let v3 = TopicModel.vector(for: "football bundesliga match results and league table")
        c.check("vectors computed", v1 != nil && v2 != nil && v3 != nil)
        if let v1, let v2, let v3 {
            let near = TopicModel.cosine(v1, v2)
            let far = TopicModel.cosine(v1, v3)
            print(String(format: "  cos(related)=%.3f cos(unrelated)=%.3f", near, far))
            c.check("related closer than unrelated", near > far)
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cs-topic-test-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<3 {
            let content = "# Context: Zed — notebook\nSource: x\nCaptured: now\n\n"
                + "import polars as pl  # bot detection dataframe pipeline \(i)"
            try? content.write(to: dir.appendingPathComponent("2026070\(i)-file\(i).md"),
                               atomically: true, encoding: .utf8)
        }
        TopicModel.refreshTopicVector(dir: dir.path)
        pump(timeout: 5, until: { TopicModel.topicVector() != nil })
        c.check("topic vector built from archive", TopicModel.topicVector() != nil)
        let onTopic = TopicModel.bucket(candidateVector:
            TopicModel.vector(for: "python polars dataframe detection code"))
        let offTopic = TopicModel.bucket(candidateVector:
            TopicModel.vector(for: "football bundesliga results"))
        print("  buckets: onTopic=\(onTopic ?? "nil") offTopic=\(offTopic ?? "nil")")
        c.check("on-topic bucket >= off-topic bucket",
                (onTopic == "high" || onTopic == "mid")
                && (offTopic == "low" || offTopic == "mid")
                && onTopic != offTopic)
        try? FileManager.default.removeItem(at: dir)
        restoreAndFinish()
    }

    /// Prequential top-1 accuracy of the action model over the REAL event
    /// log (predict-then-train, exactly like launch replay but scored).
    private static func evalLog() -> Never {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { exit(1) }
        let url = base.appendingPathComponent("ContextStack/action-events.jsonl")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            print("no action-events.jsonl yet")
            exit(1)
        }
        let ranker = ActionRanker(eventsURL: nil)
        let decoder = JSONDecoder()
        var total = 0, correct = 0
        var last50: [Bool] = []
        for line in raw.split(separator: "\n") {
            guard let e = try? decoder.decode(ActionRanker.Event.self, from: Data(line.utf8)),
                  let chosen = ActionID(rawValue: e.chosen) else { continue }
            let ctx = RankContext(targetBundleID: e.target, sourceBundleID: e.source,
                                  kind: e.kind, titleTokens: e.tokens, hourBucket: e.hour,
                                  hasSelection: e.sel ?? false)
            let presented = e.presented.compactMap(ActionID.init(rawValue:))
            guard presented.count > 1 else { continue }
            let time = Date(timeIntervalSince1970: e.ts)
            let probs = ranker.probabilities(context: ctx, presented: presented, at: time)
            let predicted = presented.max { (probs[$0] ?? 0) < (probs[$1] ?? 0) }!
            total += 1
            let hit = predicted == chosen
            if hit { correct += 1 }
            last50.append(hit)
            if last50.count > 50 { last50.removeFirst() }
            ranker.recordForEvaluation(context: ctx, presented: presented,
                                       chosen: chosen, at: time)
        }
        guard total > 0 else {
            print("no scorable events (need >1 presented action)")
            exit(1)
        }
        print("action model prequential top-1 on real log:")
        print(String(format: "  overall: %.1f%% (%d/%d events)",
                     Double(correct) / Double(total) * 100, correct, total))
        print(String(format: "  last %d: %.1f%%", last50.count,
                     Double(last50.filter { $0 }.count) / Double(last50.count) * 100))
        exit(0)
    }

    /// Multi-select stack through the production combiner.
    private static func stackTest(app1: String, app2: String, outPath: String) -> Never {
        Delivery.suppressAutoPaste = true
        CombinedCapture.forceRawDelivery = true
        let entries = [app1, app2].compactMap(makeEntry(query:))
        guard entries.count == 2 else {
            writeOut(outPath, "need two running apps with windows\n")
            exit(1)
        }
        let saved = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
        CombinedCapture.run(entries: entries)
        var combined: String?
        pump(timeout: 35, until: {
            if let s = NSPasteboard.general.string(forType: .string),
               s.hasPrefix("# Context stack") {
                combined = s
                return true
            }
            return false
        })
        if let saved { Delivery.setClipboard(saved) }
        if let combined {
            let sections = combined.components(separatedBy: "\n---\n").count
            writeOut(outPath, "stack chars=\(combined.count) sections=\(sections)\n"
                     + combined.split(separator: "\n").prefix(8).joined(separator: "\n") + "\n")
            exit(0)
        }
        writeOut(outPath, "no combined stack on clipboard within 35s\n")
        exit(1)
    }

    /// Clipboard observer shape detection; saves and restores the user's
    /// clipboard around the synthetic copy.
    private static func clipboardTest() -> Never {
        let c = Checker()
        let saved = NSPasteboard.general.string(forType: .string)
        var events: [ClipboardObserver.Event] = []
        ClipboardObserver.shared.eventSink = { events.append($0) }
        ClipboardObserver.shared.start()
        print("paste tap active: \(ClipboardObserver.shared.tapActive)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        proc.standardInput = pipe
        try? proc.run()
        pipe.fileHandleForWriting.write(Data("let x = f(y);\n{ code(); }".utf8))
        try? pipe.fileHandleForWriting.close()
        proc.waitUntilExit()

        pump(timeout: 4, until: { !events.isEmpty })
        c.check("copy event observed", !events.isEmpty)
        if let e = events.first {
            c.check("type string", e.type == "string")
            c.check("two lines", e.lines == 2)
            c.check("looks like code", e.code == true)
            c.check("not a url", e.url == false)
        }
        // Our own restore write must be ignored.
        let before = events.count
        Delivery.setClipboard(saved ?? "")
        pump(timeout: 1.5)
        c.check("self-write ignored", events.count == before)
        c.finish()
    }

    /// Focus-time tab prefetch machinery against a running browser.
    private static func prefetchTest(appQuery: String, outPath: String) -> Never {
        guard let entry = makeEntry(query: appQuery) else {
            writeOut(outPath, "no app/window for \(appQuery)\n")
            exit(1)
        }
        let status = Permissions.automationStatus(bundleID: entry.bundleID)
        BrowserCapture.prefetchTab(entry)
        pump(timeout: 8, until: { entry.knownTab != nil })
        let known = entry.knownTab
        writeOut(outPath, """
        automation: \(status.label)
        title: \(entry.title)
        knownTab: \(known.map { "\($0.url) — \($0.title)" } ?? "nil")
        """ + "\n")
        exit(known == nil ? 1 : 0)
    }

    /// Archive listing + retention against a synthetic dir.
    private static func archiveTest() -> Never {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cs-archive-test-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = Checker()
        let fm = FileManager.default
        func makeFile(_ name: String, ageDays: Double) {
            let url = dir.appendingPathComponent(name)
            try? "x".write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-ageDays * 86400)],
                ofItemAtPath: url.path)
        }
        makeFile("20260701-120000-Old-capture.md", ageDays: 10)
        makeFile("20260705-120000-Newer-capture.md", ageDays: 1)
        makeFile("20260706-120000-New-shot.png", ageDays: 0.1)
        makeFile("notes.txt", ageDays: 20) // foreign file — never touched

        let recent = CaptureArchive.recent(limit: 10, dir: dir.path)
        c.check("recent lists 3 captures (not the .txt)", recent.count == 3)
        c.check("newest first", recent.first?.displayName == "New-shot")
        c.check("display name strips timestamp", recent.last?.displayName == "Old-capture")
        c.check("image flagged", recent.first?.isImage == true)

        let removed = CaptureArchive.cleanup(retentionDays: 7, dir: dir.path)
        c.check("cleanup removed exactly the 10-day-old capture", removed == 1)
        c.check("survivors intact", CaptureArchive.recent(limit: 10, dir: dir.path).count == 2)
        c.check("foreign file untouched",
                fm.fileExists(atPath: dir.appendingPathComponent("notes.txt").path))
        c.check("retention 0 keeps forever",
                CaptureArchive.cleanup(retentionDays: 0, dir: dir.path) == 0)
        try? fm.removeItem(at: dir)
        c.finish()
    }

    private static func hotkeyTest(spec: String) -> Never {
        if let parsed = HotkeyManager.parse(spec) {
            print("ok: keyCode=\(parsed.keyCode) carbonMods=\(parsed.carbonModifiers) "
                  + "equivalent='\(parsed.keyEquivalent)'")
            exit(0)
        }
        print("invalid spec: \(spec)")
        exit(1)
    }

    /// Live selection + visible-excerpt reads against a running app.
    private static func selectionTest(appQuery: String, outPath: String) -> Never {
        var out: [String] = ["=== selection test trusted=\(AXIsProcessTrusted())"]
        if let entry = makeEntry(query: appQuery) {
            out.append("app: \(entry.appName)  title: \(entry.title)")
            let sel = SelectionCapture.selection(in: entry, allowTreeWalk: true)
            out.append("selection: \(sel.map { "\($0.count) chars: \($0.prefix(80))" } ?? "none")")
            let excerpt = SelectionCapture.visibleExcerpt(in: entry)
            out.append("visible excerpt: \(excerpt.map { "\($0.count) chars, first line: \($0.split(separator: "\n").first.map(String.init) ?? "")" } ?? "none")")
            let res = EntryResolution.compute(for: entry)
            out.append("hasTextView: \(res.hasTextView)  doc: \(res.doc ?? "nil")")
            if entry.bundleID == "dev.zed.Zed",
               let p = res.doc ?? res.remote?.exactPath {
                let row = RemoteFileCapture.zedScrollTopRow(forBufferPath: p)
                out.append("zed scrollTopRow(\(p)): \(row.map(String.init) ?? "nil")")
            }
        } else {
            out.append("no app/window matching \(appQuery)")
        }
        writeOut(outPath, out.joined(separator: "\n").appending("\n"))
        exit(0)
    }

    /// Live find-then-fetch (VS Code/JetBrains style) against a real host.
    private static func remoteFindTest(host: String, filename: String,
                                       root: String) -> Never {
        let candidate = RemoteFileCapture.Candidate(
            connection: RemoteFileCapture.Connection(host: host, port: nil, user: nil),
            exactPath: nil, filename: filename, searchRoots: [root])
        var done = false
        RemoteFileCapture.retrieve(candidate) { text, path, err in
            if let text {
                print("found \(path ?? "?"): \(text.count) chars")
            } else {
                print("error: \(err ?? "?")")
            }
            done = true
        }
        pump(timeout: 60, until: { done })
        exit(0)
    }

    /// Zed-style resolution + live fetch for a remote path.
    private static func remoteTest(path: String) -> Never {
        guard let conn = RemoteFileCapture.zedConnection(forRemotePath: path) else {
            print("no Zed SSH workspace matches \(path)")
            exit(1)
        }
        print("connection: host=\(conn.host) port=\(conn.port.map(String.init) ?? "default") "
              + "user=\(conn.user ?? "from ssh config") root=\(conn.rootPath)")
        var done = false
        RemoteFileCapture.fetch(path: path, via: conn) { text, err in
            if let text {
                print("fetched \(text.count) chars; first lines:")
                print(text.split(separator: "\n").prefix(5).joined(separator: "\n"))
            } else {
                print("fetch error: \(err ?? "?")")
            }
            done = true
        }
        pump(timeout: 60, until: { done })
        exit(0)
    }

    /// OCR through the production capture path; text lands on the clipboard.
    private static func ocrTest(appQuery: String, outPath: String) -> Never {
        Delivery.suppressAutoPaste = true
        guard let entry = makeEntry(query: appQuery) else {
            writeOut(outPath, "no app/window for \(appQuery)\n")
            exit(1)
        }
        NSPasteboard.general.clearContents()
        ScreenshotCapture.capture(entry, mode: .ocr)
        var text: String?
        pump(timeout: 15, until: {
            text = NSPasteboard.general.string(forType: .string)
            return text?.isEmpty == false
        })
        if let text, !text.isEmpty {
            let lines = text.split(separator: "\n")
            writeOut(outPath, "ocr chars=\(text.count) lines=\(lines.count)\nfirst lines:\n"
                     + lines.prefix(6).joined(separator: "\n") + "\n")
            exit(0)
        }
        writeOut(outPath, "ocr produced nothing in 15s\n")
        exit(1)
    }

    /// Production screenshot path end to end; PNG lands in the capture dir.
    private static func shotTest(appQuery: String) -> Never {
        Delivery.suppressAutoPaste = true
        guard let entry = makeEntry(query: appQuery) else {
            print("no app/window matching \(appQuery) (AX trust?)")
            exit(1)
        }
        ScreenshotCapture.capture(entry, pathOnly: true)
        pump(timeout: 12)
        exit(0)
    }
}
