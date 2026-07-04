import AppKit

/// The two-stage picker: recent windows → capture actions for the picked one.
enum PickerFlow {
    struct Action {
        let id: ActionID
        let text: String
        let subText: String
        let run: () -> Void
    }

    static func showMainPicker() {
        // Frontmost app right now is where the capture will be pasted —
        // the strongest ranking signal ("into Claude paste images, into
        // the terminal paste @paths").
        let targetBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
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
                showActions(for: entry, targetBundleID: targetBundleID)
            }
        }
    }

    private static func kindLabel(_ entry: HistoryEntry) -> String {
        if BrowserCapture.family(of: entry) != nil { return "browser tab" }
        if DocumentCapture.cheapDocumentPath(entry) != nil { return "document" }
        if DocumentCapture.titleCandidate(entry.title) != nil { return "document" }
        return "window"
    }

    private static func showActions(for entry: HistoryEntry, targetBundleID: String) {
        let context = RankContext(targetBundleID: targetBundleID,
                                  sourceBundleID: entry.bundleID,
                                  kind: kindLabel(entry),
                                  titleTokens: ActionRanker.tokenize(entry.title),
                                  hourBucket: RankContext.hourBucket())
        let actions = ranked(actionsFor(entry), context: context)
        let items = actions.enumerated().map { i, a in
            ChooserItem(text: a.text, subText: a.subText, image: nil, index: i)
        }
        Chooser.shared.show(items: items,
                            placeholder: "\(entry.appName) — \(entry.title)") { idx in
            guard let idx else { return }
            // Learn from every completed pick, even while smart ranking is
            // toggled off — the log keeps accumulating either way.
            ActionRanker.shared.record(context: context,
                                       presented: actions.map(\.id),
                                       chosen: actions[idx].id)
            actions[idx].run()
        }
    }

    /// Reorder actions by learned probability (stable: ties keep canonical
    /// order). The top row is the Enter-Enter default, so a good prediction
    /// removes the selection step entirely.
    private static func ranked(_ actions: [Action], context: RankContext) -> [Action] {
        guard Config.smartRanking, ActionRanker.shared.eventCount > 0 else { return actions }
        let probs = ActionRanker.shared.probabilities(context: context,
                                                      presented: actions.map(\.id))
        let sorted = actions.enumerated()
            .sorted { a, b in
                let pa = probs[a.element.id] ?? 0
                let pb = probs[b.element.id] ?? 0
                return pa == pb ? a.offset < b.offset : pa > pb
            }
            .map(\.element)

        // Mark the top row once the model has real evidence for this app
        // and actually deviates from the canonical order.
        guard let top = sorted.first, top.id != actions.first?.id,
              ActionRanker.shared.samples(forSource: context.sourceBundleID) >= 5,
              (probs[top.id] ?? 0) > 1.5 / Float(actions.count)
        else { return sorted }
        var marked = sorted
        marked[0] = Action(id: top.id, text: top.text,
                           subText: top.subText + "  · learned", run: top.run)
        return marked
    }

    /// Action list per entry type; this canonical order is the cold-start
    /// ranking before the learned model has data.
    private static func actionsFor(_ entry: HistoryEntry) -> [Action] {
        var acts: [Action] = []
        let isBrowser = BrowserCapture.family(of: entry) != nil
        let doc = DocumentCapture.cheapDocumentPath(entry)
        let remote = isBrowser ? nil
            : RemoteFileCapture.candidate(for: entry, docPath: doc)
        let candidate = (isBrowser || doc != nil || remote != nil)
            ? nil : DocumentCapture.titleCandidate(entry.title)

        if isBrowser {
            acts.append(Action(
                id: .pageText,
                text: "Page text",
                subText: "Readable text of the tab (JS in tab; falls back to fetching the URL)",
                run: { BrowserCapture.capturePage(entry, wantHTML: false) }))
            acts.append(Action(
                id: .linkMarkdown,
                text: "Link (markdown)",
                subText: "Copy [title](url) of the tab",
                run: { BrowserCapture.captureLink(entry) }))
            acts.append(Action(
                id: .fullHTML,
                text: "Full HTML",
                subText: "Complete HTML of the tab",
                run: { BrowserCapture.capturePage(entry, wantHTML: true) }))
        }

        if let remote {
            acts.append(Action(
                id: .fileContents,
                text: "File contents (over SSH)",
                subText: "Remote file — fetched from \(remote.displayHost) via your SSH connection",
                run: { deliverRemoteContents(remote, entry: entry) }))
            if let exact = remote.exactPath {
                let short = exact
                acts.append(Action(
                    id: .filePath,
                    text: "File path — \(short)",
                    subText: "Copy the remote document's path",
                    run: { deliverPath(exact) }))
                acts.append(Action(
                    id: .atReference,
                    text: "@-reference (Claude Code)",
                    subText: "Copy '@\(short)'",
                    run: { deliverAtReference(exact) }))
            } else {
                acts.append(Action(
                    id: .filePath,
                    text: "File path (over SSH)",
                    subText: "Locate the file on \(remote.displayHost), copy its remote path",
                    run: {
                        RemoteFileCapture.retrieve(remote) { _, path, err in
                            if let path {
                                deliverPath(path)
                            } else {
                                Delivery.notify("ContextStack",
                                                "Could not locate the file on "
                                                + "\(remote.displayHost): \(err ?? "?")")
                            }
                        }
                    }))
            }
        } else if let doc {
            let short = doc.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            acts.append(Action(
                id: .filePath,
                text: "File path — \(short)",
                subText: "Copy the document's path",
                run: { deliverPath(doc) }))
            acts.append(Action(
                id: .atReference,
                text: "@-reference (Claude Code)",
                subText: "Copy '@\(short)'",
                run: { deliverAtReference(doc) }))
            if !DocumentCapture.isDirectory(doc) {
                acts.append(Action(
                    id: .fileContents,
                    text: "File contents",
                    subText: "Copy the document text itself (text formats only)",
                    run: { deliverContents(of: doc, entry: entry) }))
            }
        } else if let candidate {
            // No AX document — locate the file named in the window title
            // (Zed and friends). Spotlight runs when the action is picked.
            acts.append(Action(
                id: .fileContents,
                text: "File contents — '\(candidate.filename)'",
                subText: "Locate by window title (Spotlight) and copy the file text; "
                    + "falls back to window text",
                run: {
                    DocumentCapture.resolveViaSpotlight(candidate) { path in
                        if let path {
                            deliverContents(of: path, entry: entry)
                        } else {
                            Delivery.notify("ContextStack",
                                            "'\(candidate.filename)' not found via Spotlight — "
                                            + "capturing window text instead")
                            AXTextCapture.captureWindowText(entry)
                        }
                    }
                }))
            acts.append(Action(
                id: .filePath,
                text: "File path — locate '\(candidate.filename)'",
                subText: "Locate by window title (Spotlight), copy the path",
                run: {
                    DocumentCapture.resolveViaSpotlight(candidate) { path in
                        if let path { deliverPath(path) } else { notifyNotFound(candidate) }
                    }
                }))
            acts.append(Action(
                id: .atReference,
                text: "@-reference (Claude Code)",
                subText: "Locate by window title (Spotlight), copy '@path'",
                run: {
                    DocumentCapture.resolveViaSpotlight(candidate) { path in
                        if let path { deliverAtReference(path) } else { notifyNotFound(candidate) }
                    }
                }))
        }

        acts.append(Action(
            id: .screenshotClipboard,
            text: "Screenshot → clipboard",
            subText: "Window snapshot as image + saved PNG (needs Screen Recording)",
            run: { ScreenshotCapture.capture(entry, pathOnly: false) }))
        acts.append(Action(
            id: .screenshotPath,
            text: "Screenshot → file path",
            subText: "Snapshot saved as PNG, its path copied (for Claude Code)",
            run: { ScreenshotCapture.capture(entry, pathOnly: true) }))

        if !isBrowser {
            acts.append(Action(
                id: .windowText,
                text: "Window text (best effort)",
                subText: "Extract visible text via Accessibility",
                run: { AXTextCapture.captureWindowText(entry) }))
        }

        acts.append(Action(
            id: .titleLine,
            text: "Title line",
            subText: "Copy 'App — window title' as plain text",
            run: {
                Delivery.setClipboard("\(entry.appName) — \(entry.title)")
                Delivery.notify("ContextStack: title copied", entry.title)
                Delivery.maybeAutoPaste()
            }))

        return acts
    }

    // ------------------------------------------------- document delivery

    private static func deliverPath(_ path: String) {
        Delivery.setClipboard(path)
        Delivery.notify("ContextStack: path copied", path)
        Delivery.maybeAutoPaste()
    }

    private static func deliverAtReference(_ path: String) {
        Delivery.setClipboard("@" + path)
        Delivery.notify("ContextStack: @-reference copied", "@" + path)
        Delivery.maybeAutoPaste()
    }

    private static func deliverContents(of path: String, entry: HistoryEntry) {
        let (data, err) = DocumentCapture.readTextFile(path)
        if let data {
            Delivery.text(entry: entry, kind: "file contents",
                          source: path, content: data)
        } else {
            Delivery.notify("ContextStack",
                            "Cannot copy contents: \(err ?? "?") — copied the path instead")
            Delivery.setClipboard(path)
        }
    }

    private static func deliverRemoteContents(_ remote: RemoteFileCapture.Candidate,
                                              entry: HistoryEntry) {
        RemoteFileCapture.retrieve(remote) { text, path, err in
            if let text {
                Delivery.text(entry: entry,
                              kind: "file contents (ssh \(remote.displayHost))",
                              source: "\(remote.displayHost):\(path ?? "?")",
                              content: text)
            } else {
                Delivery.notify("ContextStack",
                                "SSH fetch failed: \(err ?? "?")"
                                + (remote.exactPath != nil ? " — copied the path instead" : ""))
                if let exact = remote.exactPath { Delivery.setClipboard(exact) }
            }
        }
    }

    private static func notifyNotFound(_ candidate: DocumentCapture.TitleCandidate) {
        Delivery.notify("ContextStack",
                        "'\(candidate.filename)' not found via Spotlight — "
                        + "try Window text or Screenshot")
    }
}
