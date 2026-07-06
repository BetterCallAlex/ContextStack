import Foundation

/// "Relevant excerpt": pick the slice of a file that matters, not the whole
/// buffer. Three signals, combined per chunk:
///
/// - **Heuristics** (always on): error/traceback lines, TODO/FIXME markers.
/// - **Git recency**: lines changed in the working tree are the working set.
/// - **Topic** (contentLearning opt-in): embedding similarity between the
///   chunk and the session-topic vector.
///
/// The line budget adapts to feedback: capturing the *full* file shortly
/// after an excerpt of the same window means the excerpt was too narrow —
/// widen; accepted excerpts slowly tighten it back.
enum SalienceModel {
    struct Chunk {
        let startLine: Int   // 1-based
        let endLine: Int
        let text: String
        var score: Double = 0
    }

    // ------------------------------------------------------------ chunking

    /// Blank-line-separated blocks, long blocks split — works for code and
    /// prose alike.
    static func chunks(of text: String, maxChunkLines: Int = 20) -> [Chunk] {
        let lines = text.components(separatedBy: "\n")
        var out: [Chunk] = []
        var start: Int?
        func flush(_ end: Int) {
            guard let s = start else { return }
            var blockStart = s
            while blockStart <= end {
                let blockEnd = min(end, blockStart + maxChunkLines - 1)
                out.append(Chunk(startLine: blockStart + 1, endLine: blockEnd + 1,
                                 text: lines[blockStart...blockEnd].joined(separator: "\n")))
                blockStart = blockEnd + 1
            }
            start = nil
        }
        for (i, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush(i - 1)
            } else if start == nil {
                start = i
            }
        }
        flush(lines.count - 1)
        return out
    }

    // ------------------------------------------------------------- scoring

    private static let errorMarkers = ["error", "exception", "traceback",
                                       "failed", "failure", "panic", "fatal",
                                       "warning:", "stack trace"]
    private static let todoMarkers = ["todo", "fixme", "hack", "xxx:"]

    static func heuristicScore(_ text: String) -> Double {
        let lower = text.lowercased()
        var score = 0.0
        for marker in errorMarkers where lower.contains(marker) { score += 3 }
        for marker in todoMarkers where lower.contains(marker) { score += 1 }
        return min(score, 9)
    }

    /// New-side line numbers changed in the working tree (`git diff HEAD`),
    /// empty for non-repo files. Best effort — failures mean no boost.
    static func changedLines(path: String) -> Set<Int> {
        let dir = (path as NSString).deletingLastPathComponent
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", dir, "diff", "HEAD", "--unified=0", "--no-color", "--", path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let out = String(data: data, encoding: .utf8) else { return [] }
        var lines = Set<Int>()
        for line in out.split(separator: "\n") where line.hasPrefix("@@") {
            // @@ -a,b +c,d @@ — new-side range c..<c+d (d omitted = 1)
            guard let plus = line.range(of: "+") else { continue }
            let tail = line[plus.upperBound...]
            let spec = tail.prefix { $0 != " " }
            let parts = spec.split(separator: ",")
            guard let start = Int(parts.first ?? "") else { continue }
            let count = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
            for l in start..<(start + max(count, 1)) { lines.insert(l) }
        }
        return lines
    }

    /// Score all chunks. `topic` is the session-topic vector (nil = no
    /// content learning); `changed` the git working-set lines.
    static func scored(_ chunks: [Chunk], topic: [Double]?,
                       changed: Set<Int>) -> [Chunk] {
        chunks.map { chunk in
            var c = chunk
            c.score = heuristicScore(chunk.text)
            if !changed.isEmpty,
               changed.contains(where: { $0 >= chunk.startLine && $0 <= chunk.endLine }) {
                c.score += 4
            }
            if let topic, let v = TopicModel.vector(for: chunk.text) {
                c.score += max(0, TopicModel.cosine(topic, v)) * 5
            }
            return c
        }
    }

    /// The excerpt: highest-scoring chunks within the line budget, emitted
    /// in original order with line-range labels. Never empty — with no
    /// signal anywhere, the head of the file wins by position.
    static func relevantExcerpt(from text: String, budgetLines: Int,
                                topic: [Double]?, changed: Set<Int>) -> String {
        var all = scored(chunks(of: text), topic: topic, changed: changed)
        guard !all.isEmpty else { return text }
        // Positional tiebreak: earlier chunks win when nothing else does.
        for i in all.indices {
            all[i].score += 0.5 / Double(i + 1)
        }
        let ranked = all.enumerated()
            .sorted { $0.element.score == $1.element.score
                ? $0.offset < $1.offset : $0.element.score > $1.element.score }
        var used = 0
        var pickedIndices: [Int] = []
        for (idx, chunk) in ranked {
            let lines = chunk.endLine - chunk.startLine + 1
            if used + lines > budgetLines, !pickedIndices.isEmpty { continue }
            pickedIndices.append(idx)
            used += lines
            if used >= budgetLines { break }
        }
        let picked = pickedIndices.sorted().map { all[$0] }
        let totalLines = text.components(separatedBy: "\n").count
        if picked.count == all.count { return text }
        return picked.map { "[lines \($0.startLine)–\($0.endLine) of \(totalLines)]\n\($0.text)" }
            .joined(separator: "\n⋯\n")
    }

    // ------------------------------------------------- adaptive line budget

    private static let budgetKey = "excerptBudgetLines"
    private static let budgetFloor = 30
    private static let budgetCeiling = 200
    /// (entry signature, delivered at) of the last excerpt.
    private static var lastExcerpt: (signature: String, at: Date)?

    static var budgetLines: Int {
        let v = UserDefaults.standard.integer(forKey: budgetKey)
        return v == 0 ? 60 : v
    }

    static func noteExcerptDelivered(signature: String) {
        lastExcerpt = (signature, Date())
        // Accepted excerpts slowly tighten the budget back toward focus.
        let next = max(budgetFloor, Int(Double(budgetLines) * 0.98))
        UserDefaults.standard.set(next, forKey: budgetKey)
    }

    /// Full-contents capture right after an excerpt of the same window =
    /// the excerpt was too narrow. Widen.
    static func noteFullCapture(signature: String) {
        guard let last = lastExcerpt, last.signature == signature,
              Date().timeIntervalSince(last.at) < 60 else { return }
        let next = min(budgetCeiling, Int(Double(budgetLines) * 1.3))
        UserDefaults.standard.set(next, forKey: budgetKey)
        lastExcerpt = nil
        csLog("salience: full capture after excerpt — budget widened to \(next) lines")
    }

    static func signature(for entry: HistoryEntry) -> String {
        "\(entry.bundleID)|\(entry.title)"
    }
}
