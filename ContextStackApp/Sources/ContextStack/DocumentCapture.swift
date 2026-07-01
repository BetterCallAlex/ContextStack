import AppKit
import ApplicationServices

/// Resolving "which file is this window about?" — layered, because only the
/// classic document apps (Preview, TextEdit, Xcode, …) publish AXDocument:
///
///   1. AXDocument on the window
///   2. AXDocument on the app's focused UI element or one of its ancestors
///      (only if that element sits in the picked window)
///   3. an absolute path token in the window title (terminals showing a cwd,
///      editors showing a full path)
///   4. a filename token in the title ("main.rs — projectW"), located on disk
///      via Spotlight and disambiguated by the remaining title tokens — this
///      is what covers editors without AX document support, like Zed
///
/// 1–3 are cheap and synchronous (they gate which actions the chooser
/// shows); 4 runs asynchronously when the action is executed.
enum DocumentCapture {
    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "rst", "py", "js",
        "ts", "tsx", "jsx", "json", "yaml", "yml",
        "toml", "ini", "cfg", "conf", "sh", "bash",
        "zsh", "lua", "c", "h", "cpp", "hpp",
        "rs", "go", "java", "swift", "kt", "rb",
        "php", "html", "htm", "css", "scss", "xml",
        "csv", "tsv", "log", "sql", "tex", "bib",
    ]

    // ---------------------------------------------- cheap, sync (1 + 2 + 3)

    /// Strategies 1–3. Result may be a directory (a terminal's cwd).
    static func cheapDocumentPath(_ entry: HistoryEntry) -> String? {
        if let p = axDocument(entry.axWindow) { return p }
        if let p = focusedElementDocument(entry) { return p }
        if let p = pathToken(inTitle: entry.title) { return p }
        return nil
    }

    private static func axDocument(_ el: AXUIElement) -> String? {
        guard let doc = AX.string(el, "AXDocument"), !doc.isEmpty else { return nil }
        return normalizeDocumentString(doc)
    }

    static func normalizeDocumentString(_ doc: String) -> String? {
        if doc.hasPrefix("file://") {
            if let url = URL(string: doc) { return url.path }
            // Not URL-parseable (e.g. unencoded spaces) — strip and decode.
            let stripped = String(doc.dropFirst("file://".count))
            return stripped.removingPercentEncoding ?? stripped
        }
        if doc.hasPrefix("~") {
            return (doc as NSString).expandingTildeInPath
        }
        return doc.removingPercentEncoding ?? doc
    }

    private static func focusedElementDocument(_ entry: HistoryEntry) -> String? {
        let appEl = AXUIElementCreateApplication(entry.pid)
        guard let focused = AX.element(appEl, kAXFocusedUIElementAttribute as String)
        else { return nil }
        // Only trust the focused element if it lives in the picked window.
        if let win = AX.element(focused, kAXWindowAttribute as String),
           !entry.sameWindow(as: win) {
            return nil
        }
        var el: AXUIElement? = focused
        var hops = 0
        while let cur = el, hops < 8 {
            if let doc = axDocument(cur) { return doc }
            el = AX.element(cur, kAXParentAttribute as String)
            hops += 1
        }
        return nil
    }

    /// "/..." or "~/..." token in the title that exists on disk.
    static func pathToken(inTitle title: String) -> String? {
        for token in titleTokens(title)
        where token.hasPrefix("/") || token.hasPrefix("~/") {
            let expanded = (token as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) { return expanded }
        }
        return nil
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            && isDir.boolValue
    }

    // --------------------------------------------- title parsing (4, cheap)

    /// Split a window title into tokens on whitespace and common title
    /// separators, trimming decoration ("● main.rs" → "main.rs").
    private static func titleTokens(_ title: String) -> [String] {
        let separators = CharacterSet(charactersIn: " \t—–|•·»«").union(.newlines)
        let trimSet = CharacterSet(charactersIn: "●○◆*,:;()[]{}'\"<>")
        return title.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: trimSet) }
            .filter { !$0.isEmpty }
    }

    struct TitleCandidate {
        /// e.g. "main.rs"
        let filename: String
        /// Other title tokens — project name etc. — used to rank Spotlight hits.
        let hintTokens: [String]
    }

    /// A token that looks like a bare filename ("name.ext", no slashes).
    static func titleCandidate(_ title: String) -> TitleCandidate? {
        var filename: String?
        for token in titleTokens(title) {
            guard token.count <= 64, !token.contains("/"), !token.hasPrefix("."),
                  let dot = token.lastIndex(of: "."), dot != token.startIndex
            else { continue }
            let ext = token[token.index(after: dot)...]
            guard (1...8).contains(ext.count),
                  ext.allSatisfy({ $0.isLetter || $0.isNumber }),
                  ext.contains(where: \.isLetter)
            else { continue }
            filename = token
            break
        }
        guard let filename else { return nil }
        let lowerName = filename.lowercased()
        let hints = ActionRanker.tokenize(title).filter {
            $0.count >= 3 && !lowerName.contains($0)
        }
        return TitleCandidate(filename: filename, hintTokens: Array(hints.prefix(6)))
    }

    // ------------------------------------------------ Spotlight (4, async)

    /// Locate the candidate on disk. Ranked by hint-token hits in the path;
    /// bails out (nil) when several hits exist and none matches a hint —
    /// better no answer than someone else's main.rs.
    static func resolveViaSpotlight(_ candidate: TitleCandidate,
                                    completion: @escaping (String?) -> Void) {
        DispatchQueue.global().async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            let escaped = candidate.filename
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            proc.arguments = ["kMDItemFSName == \"\(escaped)\""]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
            } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let paths = String(data: data, encoding: .utf8)?
                .split(separator: "\n").map(String.init) ?? []
            let best = pickBest(paths: paths, hints: candidate.hintTokens)
            csLog("spotlight '\(candidate.filename)': \(paths.count) hits →",
                  best ?? "no confident match")
            DispatchQueue.main.async { completion(best) }
        }
    }

    static func pickBest(paths: [String], hints: [String]) -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory().lowercased()
        var scored: [(path: String, score: Int, mtime: Date)] = []
        for p in paths {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue
            else { continue }
            let lower = p.lowercased()
            var score = hints.reduce(0) { $0 + (lower.contains($1) ? 2 : 0) }
            if lower.hasPrefix(home) { score += 1 }
            if lower.contains("/library/") || lower.contains("/.trash/")
                || lower.contains("/node_modules/") {
                score -= 2
            }
            let mtime = ((try? fm.attributesOfItem(atPath: p))?[.modificationDate]
                         as? Date) ?? .distantPast
            scored.append((p, score, mtime))
        }
        guard !scored.isEmpty else { return nil }
        scored.sort {
            $0.score == $1.score ? $0.mtime > $1.mtime : $0.score > $1.score
        }
        // A single hit is trustworthy; multiple hits need hint support.
        if scored.count == 1 { return scored[0].path }
        return scored[0].score > 1 ? scored[0].path : nil
    }

    // -------------------------------------------------------- file reading

    static func readTextFile(_ path: String) -> (text: String?, error: String?) {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, textExtensions.contains(ext) else {
            return (nil, "not a text file (by extension)")
        }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return (nil, "cannot open file")
        }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: Config.maxFileBytes + 1)
        if data.contains(0) { return (nil, "binary file") }
        guard var text = String(data: data, encoding: .utf8) else {
            return (nil, "not valid UTF-8")
        }
        if data.count > Config.maxFileBytes {
            text = String(text.prefix(Config.maxFileBytes))
                + "\n\n[... truncated by ContextStack ...]"
        }
        return (text, nil)
    }
}
