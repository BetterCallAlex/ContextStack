import AppKit

/// Multi-select: capture several picked windows in one go and paste a single
/// combined markdown document — the "stack" in ContextStack. Each entry gets
/// its best *text-yielding* capture, in order of relevance philosophy:
/// selection → remote file → local file → page text → visible excerpt →
/// window text → OCR → title line (never fails).
enum CombinedCapture {
    private static let overallTimeout: TimeInterval = 30

    static func run(entries: [HistoryEntry]) {
        guard !entries.isEmpty else { return }
        var sections = [String?](repeating: nil, count: entries.count)
        let group = DispatchGroup()

        for (i, entry) in entries.enumerated() {
            group.enter()
            captureText(entry) { content, sourceNote in
                let header = "## \(i + 1) · \(entry.appName) — \(entry.title)\n"
                    + (sourceNote.map { "Source: \($0)\n" } ?? "")
                sections[i] = header + "\n"
                    + (content ?? "*[capture failed]*") + "\n"
                group.leave()
            }
        }

        var delivered = false
        func deliver() {
            guard !delivered else { return }
            delivered = true
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let full = "# Context stack — \(entries.count) items "
                + "(\(fmt.string(from: Date())))\n\n"
                + sections.map { $0 ?? "*[capture timed out]*\n" }
                    .joined(separator: "\n---\n\n")
            Delivery.setClipboard(full)
            Delivery.maybeAutoPaste()
            DispatchQueue.global(qos: .utility).async {
                let stamp = DateFormatter()
                stamp.dateFormat = "yyyyMMdd-HHmmss"
                let path = Delivery.saveCapture(
                    basename: "\(stamp.string(from: Date()))-stack-of-\(entries.count).md",
                    content: full)
                Delivery.notify("ContextStack: \(entries.count)-item stack copied",
                                "Saved: \(path ?? "not saved")")
            }
        }

        group.notify(queue: .main) { deliver() }
        // Belt and braces: a hung fetch must not swallow the whole stack.
        DispatchQueue.main.asyncAfter(deadline: .now() + overallTimeout) { deliver() }
    }

    /// Best text capture for one entry; completion on main with
    /// (content, source-note). Falls through the chain until something
    /// yields; the title line terminates it — a stack section never dies.
    static func captureText(_ entry: HistoryEntry,
                            completion: @escaping (String?, String?) -> Void) {
        let resolution = entry.resolution()

        if resolution.selection != nil {
            let live = SelectionCapture.selection(
                in: entry, allowTreeWalk: !resolution.isBrowser)
            if let text = live ?? resolution.selection {
                completion(text, "selection in \(entry.appName)")
                return
            }
        }
        if resolution.isBrowser {
            BrowserCapture.fetchPage(entry, wantHTML: false) { content, url, _ in
                if let content {
                    completion(content, url)
                } else {
                    completion("*[page fetch failed]*", url)
                }
            }
            return
        }
        if let remote = resolution.remote {
            RemoteFileCapture.retrieve(remote) { text, path, _ in
                if let text {
                    completion(text, "\(remote.displayHost):\(path ?? "?")")
                } else {
                    fallbackAXChain(entry, resolution: resolution, completion: completion)
                }
            }
            return
        }
        if let doc = resolution.doc, !DocumentCapture.isDirectory(doc),
           case let (text?, _) = DocumentCapture.readTextFile(doc) {
            completion(text, doc)
            return
        }
        fallbackAXChain(entry, resolution: resolution, completion: completion)
    }

    private static func fallbackAXChain(_ entry: HistoryEntry,
                                        resolution: EntryResolution,
                                        completion: @escaping (String?, String?) -> Void) {
        if resolution.hasTextView, let excerpt = SelectionCapture.visibleExcerpt(in: entry) {
            completion(excerpt, "visible excerpt of \(entry.appName)")
            return
        }
        if let text = AXTextCapture.windowText(entry) {
            completion(text, "window text of \(entry.appName)")
            return
        }
        ScreenshotCapture.ocrText(entry) { text in
            if let text {
                completion(text, "OCR of \(entry.appName)")
            } else {
                completion("\(entry.appName) — \(entry.title)", "title only")
            }
        }
    }
}
