import AppKit

// Before anything else — the CLI modes below read Config too.
Config.registerDefaults()

if CommandLine.arguments.contains("--ranker-selftest") {
    RankerSelfTest.run()
}
if CommandLine.arguments.contains("--doc-selftest") {
    DocSelfTest.run()
}
if CommandLine.arguments.contains("--remote-selftest") {
    RemoteSelfTest.run()
}
if let i = CommandLine.arguments.firstIndex(of: "--render-icon"),
   CommandLine.arguments.count > i + 1 {
    IconKit.renderIconset(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}
// Topic embedding sanity: --topic-test
if CommandLine.arguments.contains("--topic-test") {
    var failures = 0
    func check(_ name: String, _ ok: Bool) {
        if !ok { failures += 1 }
        print("  \(ok ? "ok " : "MISS") \(name)")
    }
    let wasOn = Config.contentLearning
    Config.contentLearning = true
    defer { Config.contentLearning = wasOn }
    check("NLEmbedding available", TopicModel.available)
    guard TopicModel.available else { print("FAIL"); exit(1) }

    let v1 = TopicModel.vector(for: "python dataframe pandas notebook bot detection analysis")
    let v2 = TopicModel.vector(for: "polars dataframe python code for the detection notebook")
    let v3 = TopicModel.vector(for: "football bundesliga match results and league table")
    check("vectors computed", v1 != nil && v2 != nil && v3 != nil)
    if let v1, let v2, let v3 {
        let near = TopicModel.cosine(v1, v2)
        let far = TopicModel.cosine(v1, v3)
        print(String(format: "  cos(related)=%.3f cos(unrelated)=%.3f", near, far))
        check("related closer than unrelated", near > far)
    }

    // Topic vector from a synthetic archive + bucketing end to end.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cs-topic-test-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for i in 0..<3 {
        let content = "# Context: Zed — notebook\nSource: x\nCaptured: now\n\n"
            + "import polars as pl  # bot detection dataframe pipeline \(i)"
        try? content.write(to: dir.appendingPathComponent("2026070\(i)-file\(i).md"),
                           atomically: true, encoding: .utf8)
    }
    TopicModel.refreshTopicVector(dir: dir.path)
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, TopicModel.topicVector() == nil {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    check("topic vector built from archive", TopicModel.topicVector() != nil)
    let onTopic = TopicModel.bucket(candidateVector:
        TopicModel.vector(for: "python polars dataframe detection code"))
    let offTopic = TopicModel.bucket(candidateVector:
        TopicModel.vector(for: "football bundesliga results"))
    print("  buckets: onTopic=\(onTopic ?? "nil") offTopic=\(offTopic ?? "nil")")
    check("on-topic bucket >= off-topic bucket",
          (onTopic == "high" || onTopic == "mid")
          && (offTopic == "low" || offTopic == "mid")
          && onTopic != offTopic)
    print(failures == 0 ? "PASS" : "FAIL (\(failures))")
    exit(failures == 0 ? 0 : 1)
}

// Prequential evaluation of the REAL event logs: --eval-log
// Reports top-1 accuracy of the action model over your actual pick history
// (predict-then-train over the log, exactly like launch replay but scored).
if CommandLine.arguments.contains("--eval-log") {
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

// Multi-select stack through the production combiner:
// --stack-test <app1> <app2> <out>   (run via open -n -W ... --args)
if let i = CommandLine.arguments.firstIndex(of: "--stack-test"),
   CommandLine.arguments.count > i + 3 {
    Delivery.suppressAutoPaste = true
    let outPath = CommandLine.arguments[i + 3]
    var entries: [HistoryEntry] = []
    for q in [CommandLine.arguments[i + 1], CommandLine.arguments[i + 2]] {
        guard let target = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").lowercased().contains(q.lowercased())
        }), let win = AX.element(AX.application(target.processIdentifier),
                                 kAXFocusedWindowAttribute as String) else { continue }
        entries.append(HistoryEntry(
            axWindow: win, pid: target.processIdentifier,
            appName: target.localizedName ?? "?",
            bundleID: target.bundleIdentifier ?? "",
            title: AX.string(win, kAXTitleAttribute as String) ?? ""))
    }
    guard entries.count == 2 else {
        try? "need two running apps with windows\n"
            .write(toFile: outPath, atomically: true, encoding: .utf8)
        exit(1)
    }
    let saved = NSPasteboard.general.string(forType: .string)
    NSPasteboard.general.clearContents()
    CombinedCapture.run(entries: entries)
    let deadline = Date().addingTimeInterval(35)
    var combined: String?
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))
        if let s = NSPasteboard.general.string(forType: .string),
           s.hasPrefix("# Context stack") {
            combined = s
            break
        }
    }
    if let saved { Delivery.setClipboard(saved) }
    if let combined {
        let sections = combined.components(separatedBy: "\n---\n").count
        try? ("stack chars=\(combined.count) sections=\(sections)\n"
              + combined.split(separator: "\n").prefix(8).joined(separator: "\n") + "\n")
            .write(toFile: outPath, atomically: true, encoding: .utf8)
        exit(0)
    }
    try? "no combined stack on clipboard within 35s\n"
        .write(toFile: outPath, atomically: true, encoding: .utf8)
    exit(1)
}

// Clipboard observer shape detection: --clipboard-test
// Saves and restores the user's clipboard around the synthetic copy.
if CommandLine.arguments.contains("--clipboard-test") {
    var failures = 0
    func check(_ name: String, _ ok: Bool) {
        if !ok { failures += 1 }
        print("  \(ok ? "ok " : "MISS") \(name)")
    }
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

    let deadline = Date().addingTimeInterval(4)
    while Date() < deadline, events.isEmpty {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    check("copy event observed", !events.isEmpty)
    if let e = events.first {
        check("type string", e.type == "string")
        check("two lines", e.lines == 2)
        check("looks like code", e.code == true)
        check("not a url", e.url == false)
    }
    // Our own restore write must be ignored.
    let before = events.count
    if let saved { Delivery.setClipboard(saved) } else { Delivery.setClipboard("") }
    let deadline2 = Date().addingTimeInterval(1.5)
    while Date() < deadline2 {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    check("self-write ignored", events.count == before)
    print(failures == 0 ? "PASS" : "FAIL (\(failures))")
    exit(failures == 0 ? 0 : 1)
}

// Focus-time tab prefetch machinery: --prefetch-test <browser-query> <out>
if let i = CommandLine.arguments.firstIndex(of: "--prefetch-test"),
   CommandLine.arguments.count > i + 2 {
    let outPath = CommandLine.arguments[i + 2]
    let q = CommandLine.arguments[i + 1].lowercased()
    guard let target = NSWorkspace.shared.runningApplications.first(where: {
        ($0.localizedName ?? "").lowercased().contains(q)
    }), let win = AX.element(AX.application(target.processIdentifier),
                             kAXFocusedWindowAttribute as String) else {
        try? "no app/window for \(q)\n".write(toFile: outPath, atomically: true,
                                              encoding: .utf8)
        exit(1)
    }
    let entry = HistoryEntry(axWindow: win, pid: target.processIdentifier,
                             appName: target.localizedName ?? "?",
                             bundleID: target.bundleIdentifier ?? "",
                             title: AX.string(win, kAXTitleAttribute as String) ?? "")
    let status = Permissions.automationStatus(bundleID: entry.bundleID)
    BrowserCapture.prefetchTab(entry)
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline, entry.knownTab == nil {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    let known = entry.knownTab
    try? ("""
    automation: \(status.label)
    title: \(entry.title)
    knownTab: \(known.map { "\($0.url) — \($0.title)" } ?? "nil")
    """ + "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    exit(known == nil ? 1 : 0)
}

// Archive listing + retention against a synthetic dir: --archive-test
if CommandLine.arguments.contains("--archive-test") {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cs-archive-test-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    var failures = 0
    func check(_ name: String, _ ok: Bool) {
        if !ok { failures += 1 }
        print("  \(ok ? "ok " : "MISS") \(name)")
    }
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
    check("recent lists 3 captures (not the .txt)", recent.count == 3)
    check("newest first", recent.first?.displayName == "New-shot")
    check("display name strips timestamp", recent.last?.displayName == "Old-capture")
    check("image flagged", recent.first?.isImage == true)

    let removed = CaptureArchive.cleanup(retentionDays: 7, dir: dir.path)
    check("cleanup removed exactly the 10-day-old capture", removed == 1)
    check("survivors intact", CaptureArchive.recent(limit: 10, dir: dir.path).count == 2)
    check("foreign file untouched",
          fm.fileExists(atPath: dir.appendingPathComponent("notes.txt").path))
    check("retention 0 keeps forever",
          CaptureArchive.cleanup(retentionDays: 0, dir: dir.path) == 0)
    print(failures == 0 ? "PASS" : "FAIL (\(failures))")
    exit(failures == 0 ? 0 : 1)
}

// Parser check: --hotkey-test <spec>
if let i = CommandLine.arguments.firstIndex(of: "--hotkey-test"),
   CommandLine.arguments.count > i + 1 {
    let spec = CommandLine.arguments[i + 1]
    if let parsed = HotkeyManager.parse(spec) {
        print("ok: keyCode=\(parsed.keyCode) carbonMods=\(parsed.carbonModifiers) "
              + "equivalent='\(parsed.keyEquivalent)'")
        exit(0)
    }
    print("invalid spec: \(spec)")
    exit(1)
}

// Live check of selection + visible-excerpt reads against a running app:
// --selection-test <app-query> <out-file>  (run via open -n -W ... --args)
if let i = CommandLine.arguments.firstIndex(of: "--selection-test"),
   CommandLine.arguments.count > i + 2 {
    var out: [String] = ["=== selection test trusted=\(AXIsProcessTrusted())"]
    let q = CommandLine.arguments[i + 1].lowercased()
    if let target = NSWorkspace.shared.runningApplications.first(where: {
        ($0.localizedName ?? "").lowercased().contains(q)
    }) {
        let appEl = AX.application(target.processIdentifier)
        if let win = AX.element(appEl, kAXFocusedWindowAttribute as String) {
            let entry = HistoryEntry(axWindow: win, pid: target.processIdentifier,
                                     appName: target.localizedName ?? "?",
                                     bundleID: target.bundleIdentifier ?? "",
                                     title: AX.string(win, kAXTitleAttribute as String) ?? "")
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
            out.append("no focused window")
        }
    } else {
        out.append("no app matching \(q)")
    }
    try? out.joined(separator: "\n").appending("\n")
        .write(toFile: CommandLine.arguments[i + 2], atomically: true, encoding: .utf8)
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--perf-test"),
   CommandLine.arguments.count > i + 2 {
    PerfTest.run(appQuery: CommandLine.arguments[i + 1],
                 outPath: CommandLine.arguments[i + 2])
}
if let i = CommandLine.arguments.firstIndex(of: "--diag"),
   CommandLine.arguments.count > i + 2 {
    Diagnostics.run(appQuery: CommandLine.arguments[i + 1],
                    outPath: CommandLine.arguments[i + 2])
}
// Live test of the find-then-fetch path (VS Code/JetBrains style):
// --remote-find-test <host> <filename> [root]
if let i = CommandLine.arguments.firstIndex(of: "--remote-find-test"),
   CommandLine.arguments.count > i + 2 {
    let conn = RemoteFileCapture.Connection(host: CommandLine.arguments[i + 1],
                                            port: nil, user: nil)
    let root = CommandLine.arguments.count > i + 3 ? CommandLine.arguments[i + 3] : "."
    let candidate = RemoteFileCapture.Candidate(
        connection: conn, exactPath: nil,
        filename: CommandLine.arguments[i + 2], searchRoots: [root])
    var done = false
    RemoteFileCapture.retrieve(candidate) { text, path, err in
        if let text {
            print("found \(path ?? "?"): \(text.count) chars")
        } else {
            print("error: \(err ?? "?")")
        }
        done = true
    }
    while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--remote-test"),
   CommandLine.arguments.count > i + 1 {
    let path = CommandLine.arguments[i + 1]
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
    while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
    exit(0)
}

// OCR through the production capture path; text lands on the clipboard.
// --ocr-test <app-query> <out-file>   (run via open -n -W ... --args)
if let i = CommandLine.arguments.firstIndex(of: "--ocr-test"),
   CommandLine.arguments.count > i + 2 {
    Delivery.suppressAutoPaste = true
    let outPath = CommandLine.arguments[i + 2]
    let q = CommandLine.arguments[i + 1].lowercased()
    guard let target = NSWorkspace.shared.runningApplications.first(where: {
        ($0.localizedName ?? "").lowercased().contains(q)
    }), let win = AX.element(AX.application(target.processIdentifier),
                             kAXFocusedWindowAttribute as String) else {
        try? "no app/window for \(q)\n".write(toFile: outPath, atomically: true,
                                              encoding: .utf8)
        exit(1)
    }
    let entry = HistoryEntry(axWindow: win, pid: target.processIdentifier,
                             appName: target.localizedName ?? "?",
                             bundleID: target.bundleIdentifier ?? "",
                             title: AX.string(win, kAXTitleAttribute as String) ?? "")
    NSPasteboard.general.clearContents()
    ScreenshotCapture.capture(entry, mode: .ocr)
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))
        if let s = NSPasteboard.general.string(forType: .string), !s.isEmpty {
            let lines = s.split(separator: "\n")
            try? ("ocr chars=\(s.count) lines=\(lines.count)\nfirst lines:\n"
                  + lines.prefix(6).joined(separator: "\n") + "\n")
                .write(toFile: outPath, atomically: true, encoding: .utf8)
            exit(0)
        }
    }
    try? "ocr produced nothing in 15s\n".write(toFile: outPath, atomically: true,
                                               encoding: .utf8)
    exit(1)
}

// End-to-end test of the production screenshot path against a running app's
// focused window; run via `open -n -W ... --args --shot-test <app>` so TCC
// grants apply. Writes the PNG to the capture dir like the real action.
if let i = CommandLine.arguments.firstIndex(of: "--shot-test"),
   CommandLine.arguments.count > i + 1 {
    Delivery.suppressAutoPaste = true
    let q = CommandLine.arguments[i + 1].lowercased()
    guard let target = NSWorkspace.shared.runningApplications.first(where: {
        ($0.localizedName ?? "").lowercased().contains(q)
    }) else {
        print("no running app matching \(q)")
        exit(1)
    }
    let appEl = AXUIElementCreateApplication(target.processIdentifier)
    guard let win = AX.element(appEl, kAXFocusedWindowAttribute as String) else {
        print("no focused window for \(target.localizedName ?? q) (AX trust?)")
        exit(1)
    }
    let entry = HistoryEntry(axWindow: win, pid: target.processIdentifier,
                             appName: target.localizedName ?? "?",
                             bundleID: target.bundleIdentifier ?? "",
                             title: AX.string(win, kAXTitleAttribute as String) ?? "")
    ScreenshotCapture.capture(entry, pathOnly: true)
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--ui-shots"),
   CommandLine.arguments.count > i + 1 {
    UIShots.requestedDir = CommandLine.arguments[i + 1]
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
