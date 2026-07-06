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
