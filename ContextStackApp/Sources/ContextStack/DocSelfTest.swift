import Foundation

/// `ContextStack --doc-selftest` — exercises the document-resolution layers
/// that don't need Accessibility: AXDocument string normalization, title
/// parsing, path-token detection and Spotlight-hit ranking. Ends with an
/// informational live mdfind query (not part of pass/fail — Spotlight
/// indexing varies per machine).
enum DocSelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ got: String?, _ want: String?) {
        let ok = got == want
        if !ok { failures += 1 }
        print("  \(ok ? "ok " : "MISS") \(name): got \(got ?? "nil"), want \(want ?? "nil")")
    }

    static func run() {
        print("doc selftest")

        // 1. AXDocument normalization
        check("file URL percent-encoded",
              DocumentCapture.normalizeDocumentString("file:///Users/x/My%20Doc.pdf"),
              "/Users/x/My Doc.pdf")
        check("file URL unencoded space",
              DocumentCapture.normalizeDocumentString("file:///Users/x/My Doc.pdf"),
              "/Users/x/My Doc.pdf")
        check("plain path", DocumentCapture.normalizeDocumentString("/tmp/a.txt"), "/tmp/a.txt")

        // 2. title → filename candidate
        check("zed style title",
              DocumentCapture.titleCandidate("main.rs — projectW")?.filename, "main.rs")
        check("dirty-buffer marker",
              DocumentCapture.titleCandidate("● app.tsx — dashboard — Zed")?.filename, "app.tsx")
        check("terminal title no candidate",
              DocumentCapture.titleCandidate("Terminal — -zsh — 80×24")?.filename, nil)
        check("version number is not a file",
              DocumentCapture.titleCandidate("Safari 18.2")?.filename, nil)
        check("dotfile rejected",
              DocumentCapture.titleCandidate(".zshrc — nano")?.filename, nil)
        let hints = DocumentCapture.titleCandidate("main.rs — projectW")?.hintTokens ?? []
        let hintsOK = hints.contains("projectw")
        if !hintsOK { failures += 1 }
        print("  \(hintsOK ? "ok " : "MISS") hint tokens carry project name: \(hints)")

        // 3. path token in title (needs a real file)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cs-doc-selftest-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileA = dir.appendingPathComponent("zzqproja/notes.md")
        let fileB = dir.appendingPathComponent("zzqother/notes.md")
        try? FileManager.default.createDirectory(
            at: fileA.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: fileB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "a".write(to: fileA, atomically: true, encoding: .utf8)
        try? "b".write(to: fileB, atomically: true, encoding: .utf8)

        check("absolute path in title",
              DocumentCapture.pathToken(inTitle: "\(fileA.path) — vim"), fileA.path)
        check("nonexistent path ignored",
              DocumentCapture.pathToken(inTitle: "~/zzq-does-not-exist — zsh"), nil)

        // 4. Spotlight-hit ranking
        check("hint disambiguates duplicates",
              DocumentCapture.pickBest(paths: [fileB.path, fileA.path],
                                       hints: ["zzqproja"]),
              fileA.path)
        check("ambiguous without hints bails",
              DocumentCapture.pickBest(paths: [fileA.path, fileB.path], hints: []),
              nil)
        check("single hit trusted",
              DocumentCapture.pickBest(paths: [fileA.path], hints: []), fileA.path)

        // 5. live Spotlight round trip — informational only
        let candidate = DocumentCapture.TitleCandidate(filename: "handoff.md",
                                                       hintTokens: ["contextstack"])
        var live: String?
        var done = false
        DocumentCapture.resolveViaSpotlight(candidate) { live = $0; done = true }
        let deadline = Date().addingTimeInterval(10)
        while !done, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        print("  info: live mdfind 'handoff.md' (hint contextstack) → \(live ?? "no match")")

        print(failures == 0 ? "PASS" : "FAIL (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}
