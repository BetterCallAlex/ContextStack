import AppKit

/// The two-stage picker: recent windows → capture actions for the picked one.
enum PickerFlow {
    struct Action {
        let text: String
        let subText: String
        let run: () -> Void
    }

    static func showMainPicker() {
        let entries = FocusTracker.shared.pickerEntries()
        guard !entries.isEmpty else {
            Delivery.notify("ContextStack",
                            "No recent windows yet — switch between some apps first")
            return
        }
        let items = entries.enumerated().map { i, e in
            ChooserItem(
                text: "\(e.appName) — \(e.title.isEmpty ? "(untitled)" : e.title)",
                subText: "\(kindLabel(e)) · \(e.agoText)",
                image: e.appIcon,
                index: i)
        }
        Chooser.shared.show(items: items, placeholder: "Recent windows…") { idx in
            guard let idx else { return }
            let entry = entries[idx]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                showActions(for: entry)
            }
        }
    }

    private static func kindLabel(_ entry: HistoryEntry) -> String {
        if BrowserCapture.family(of: entry) != nil { return "browser tab" }
        if DocumentCapture.documentPath(entry) != nil { return "document" }
        return "window"
    }

    private static func showActions(for entry: HistoryEntry) {
        let actions = actionsFor(entry)
        let items = actions.enumerated().map { i, a in
            ChooserItem(text: a.text, subText: a.subText, image: nil, index: i)
        }
        Chooser.shared.show(items: items,
                            placeholder: "\(entry.appName) — \(entry.title)") { idx in
            guard let idx else { return }
            actions[idx].run()
        }
    }

    /// Action list per entry type — same set and order as the Hammerspoon
    /// spoon, so the first row is the smart default (Enter-Enter flow).
    private static func actionsFor(_ entry: HistoryEntry) -> [Action] {
        var acts: [Action] = []
        let isBrowser = BrowserCapture.family(of: entry) != nil
        let doc = DocumentCapture.documentPath(entry)

        if isBrowser {
            acts.append(Action(
                text: "Page text",
                subText: "Readable text of the tab (JS in tab; falls back to fetching the URL)",
                run: { BrowserCapture.capturePage(entry, wantHTML: false) }))
            acts.append(Action(
                text: "Link (markdown)",
                subText: "Copy [title](url) of the tab",
                run: { BrowserCapture.captureLink(entry) }))
            acts.append(Action(
                text: "Full HTML",
                subText: "Complete HTML of the tab",
                run: { BrowserCapture.capturePage(entry, wantHTML: true) }))
        }

        if let doc {
            let short = doc.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            acts.append(Action(
                text: "File path — \(short)",
                subText: "Copy the document's path",
                run: {
                    Delivery.setClipboard(doc)
                    Delivery.notify("ContextStack: path copied", doc)
                    Delivery.maybeAutoPaste()
                }))
            acts.append(Action(
                text: "@-reference (Claude Code)",
                subText: "Copy '@\(short)'",
                run: {
                    Delivery.setClipboard("@" + doc)
                    Delivery.notify("ContextStack: @-reference copied", "@" + doc)
                    Delivery.maybeAutoPaste()
                }))
            acts.append(Action(
                text: "File contents",
                subText: "Copy the document text itself (text formats only)",
                run: {
                    let (data, err) = DocumentCapture.readTextFile(doc)
                    if let data {
                        Delivery.text(entry: entry, kind: "file contents",
                                      source: doc, content: data)
                    } else {
                        Delivery.notify("ContextStack",
                                        "Cannot copy contents: \(err ?? "?") — copied the path instead")
                        Delivery.setClipboard(doc)
                    }
                }))
        }

        acts.append(Action(
            text: "Screenshot → clipboard",
            subText: "Window snapshot as image + saved PNG (needs Screen Recording)",
            run: { ScreenshotCapture.capture(entry, pathOnly: false) }))
        acts.append(Action(
            text: "Screenshot → file path",
            subText: "Snapshot saved as PNG, its path copied (for Claude Code)",
            run: { ScreenshotCapture.capture(entry, pathOnly: true) }))

        if !isBrowser {
            acts.append(Action(
                text: "Window text (best effort)",
                subText: "Extract visible text via Accessibility",
                run: { AXTextCapture.captureWindowText(entry) }))
        }

        acts.append(Action(
            text: "Title line",
            subText: "Copy 'App — window title' as plain text",
            run: {
                Delivery.setClipboard("\(entry.appName) — \(entry.title)")
                Delivery.notify("ContextStack: title copied", entry.title)
                Delivery.maybeAutoPaste()
            }))

        return acts
    }
}
