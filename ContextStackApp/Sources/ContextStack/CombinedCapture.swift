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
            offerDelivery(full, count: entries.count)
        }

        group.notify(queue: .main) { deliver() }
        // Belt and braces: a hung fetch must not swallow the whole stack.
        DispatchQueue.main.asyncAfter(deadline: .now() + overallTimeout) { deliver() }
    }

    /// CLI test modes bypass the interactive raw-vs-summary chooser.
    static var forceRawDelivery = false

    /// With the on-device LLM available, the assembled stack offers a
    /// raw-vs-condensed choice; without it, raw pastes directly as before.
    private static func offerDelivery(_ full: String, count: Int) {
        guard LocalLLM.isAvailable, !forceRawDelivery else {
            deliverRaw(full, count: count)
            return
        }
        let items = [
            ChooserItem(text: "Paste stack (raw)",
                        subText: "\(count) sections · \(full.count) chars",
                        image: ActionID.symbolImage("square.stack.3d.up"), index: 0),
            ChooserItem(text: "Summarize, then paste",
                        subText: "Condensed on-device (Apple Intelligence) — nothing leaves the Mac",
                        image: ActionID.symbolImage("sparkles"), index: 1),
        ]
        Chooser.shared.show(items: items, placeholder: "Context stack ready…") { idx in
            guard let idx else { return }
            if idx == 0 {
                deliverRaw(full, count: count)
                return
            }
            Delivery.notify("ContextStack", "Summarizing \(count)-item stack…")
            LocalLLM.summarizeStack(full) { summary in
                if let summary {
                    deliverSummary(summary, full: full, count: count)
                } else {
                    Delivery.failure("ContextStack",
                                     "Summarization failed — pasting the raw stack")
                    deliverRaw(full, count: count)
                }
            }
        }
    }

    private static func stamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return fmt.string(from: Date())
    }

    private static func deliverRaw(_ full: String, count: Int) {
        Delivery.setClipboard(full)
        Delivery.maybeAutoPaste()
        DispatchQueue.global(qos: .utility).async {
            let name = "\(stamp())-stack-of-\(count).md"
            let path = Delivery.saveCapture(basename: name, content: full)
            if let path {
                LocalLLM.tagCapture(file: URL(fileURLWithPath: path), text: full)
            }
            Delivery.notify("ContextStack: \(count)-item stack copied",
                            "Saved: \(path ?? "not saved")")
        }
    }

    private static func deliverSummary(_ summary: String, full: String, count: Int) {
        let body = "# Context stack — \(count) items (condensed on-device)\n\n" + summary
        Delivery.setClipboard(body)
        Delivery.maybeAutoPaste()
        DispatchQueue.global(qos: .utility).async {
            let base = stamp()
            _ = Delivery.saveCapture(basename: "\(base)-stack-of-\(count).md",
                                     content: full)
            let path = Delivery.saveCapture(
                basename: "\(base)-stack-of-\(count)-summary.md", content: body)
            Delivery.notify("ContextStack: condensed stack copied",
                            "Summary + full stack saved: \(path ?? "not saved")")
        }
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
