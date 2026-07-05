import AppKit
import ApplicationServices

/// "Relevant lines, not whole files" — two direct Accessibility signals:
///
/// - **Selected text**: if the user has a selection in the picked window,
///   that *is* the relevant content, stated by them. Read from the app's
///   focused element (when it lives in the picked window), falling back to
///   a bounded tree walk — selections persist in background windows for
///   most AppKit apps.
/// - **Visible excerpt**: what's scrolled into view is what they were
///   reading. `AXVisibleCharacterRange` of the window's main text area,
///   extracted with the parameterized `AXStringForRange` so huge editor
///   buffers never cross the process boundary.
enum SelectionCapture {
    private static let walkBudget = 1200

    // ---------------------------------------------------------- selection

    /// Live selection in the entry's window, nil when empty/whitespace.
    /// Tree walk is skipped for browsers (huge AX trees; the focused-element
    /// path still works there).
    static func selection(in entry: HistoryEntry, allowTreeWalk: Bool) -> String? {
        if let focused = focusedElement(in: entry),
           let s = nonEmpty(AX.string(focused, kAXSelectedTextAttribute as String)) {
            return s
        }
        guard allowTreeWalk else { return nil }
        var found: String?
        var budget = walkBudget
        walk(entry.axWindow, depth: 0, budget: &budget) { el in
            if let s = nonEmpty(AX.string(el, kAXSelectedTextAttribute as String)) {
                found = s
                return true
            }
            return false
        }
        return found
    }

    static func captureSelection(_ entry: HistoryEntry, snapshot: String?) {
        let text = selection(in: entry,
                             allowTreeWalk: BrowserCapture.family(of: entry) == nil)
            ?? snapshot
        guard let text else {
            Delivery.failure("ContextStack",
                             "No selection found in that window anymore")
            return
        }
        Delivery.text(entry: entry, kind: "selected text",
                      source: entry.appName, content: cap(text))
    }

    // ----------------------------------------------------- visible excerpt

    /// The text currently scrolled into view in the window's main text area.
    static func visibleExcerpt(in entry: HistoryEntry) -> String? {
        guard let el = mainTextElement(in: entry),
              let range = visibleRange(of: el), range.length > 0 else { return nil }

        var rangeCopy = range
        if let param = AXValueCreate(.cfRange, &rangeCopy) {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                el, kAXStringForRangeParameterizedAttribute as CFString,
                param, &out) == .success,
               let s = nonEmpty(out as? String) {
                return s
            }
        }
        // Fallback: substring of the full value. AX ranges count UTF-16
        // units; Swift counts grapheme clusters — close enough for a
        // fallback that mostly serves small views.
        if let full = AX.string(el, kAXValueAttribute as String),
           full.count >= range.location + range.length {
            let start = full.index(full.startIndex, offsetBy: range.location)
            let end = full.index(start, offsetBy: range.length)
            return nonEmpty(String(full[start..<end]))
        }
        return nil
    }

    /// True when the window exposes a text view we could excerpt from —
    /// gates the action so apps like Zed (no AX text elements) don't get a
    /// dead menu row unless the Zed-session path below can serve them.
    static func hasVisibleTextView(_ entry: HistoryEntry) -> Bool {
        mainTextElement(in: entry) != nil
    }

    static func captureVisibleExcerpt(_ entry: HistoryEntry, resolution: EntryResolution) {
        if let text = visibleExcerpt(in: entry) {
            Delivery.text(entry: entry, kind: "visible excerpt",
                          source: entry.appName, content: cap(text))
            return
        }
        zedSessionExcerpt(entry, resolution: resolution) { text, source in
            if let text {
                Delivery.text(entry: entry, kind: "visible excerpt (Zed session)",
                              source: source, content: text)
            } else {
                Delivery.notify("ContextStack",
                                "No readable text view — capturing full window text instead")
                AXTextCapture.captureWindowText(entry)
            }
        }
    }

    // ------------------------------------------- Zed session viewport

    /// Zed exposes no text through AX, but its session db records the top
    /// visible row per buffer. Slice the file (local read or SSH fetch)
    /// from that row for one estimated viewport.
    private static func zedSessionExcerpt(
        _ entry: HistoryEntry, resolution: EntryResolution,
        completion: @escaping (String?, String?) -> Void) {
        guard entry.bundleID == "dev.zed.Zed",
              let path = resolution.doc ?? resolution.remote?.exactPath else {
            completion(nil, nil)
            return
        }
        let topRow = RemoteFileCapture.zedScrollTopRow(forBufferPath: path) ?? 0
        let lineCount = viewportLines(entry)

        func deliverSlice(_ full: String) {
            let lines = full.components(separatedBy: "\n")
            let start = min(topRow, max(0, lines.count - 1))
            let end = min(lines.count, start + lineCount)
            completion(lines[start..<end].joined(separator: "\n"),
                       "\(path)#L\(start + 1)-\(end)")
        }

        if FileManager.default.fileExists(atPath: path) {
            let (text, _) = DocumentCapture.readTextFile(path)
            if let text { deliverSlice(text) } else { completion(nil, nil) }
        } else if let remote = resolution.remote {
            RemoteFileCapture.retrieve(remote) { text, _, _ in
                if let text { deliverSlice(text) } else { completion(nil, nil) }
            }
        } else {
            completion(nil, nil)
        }
    }

    /// Rough viewport height in text lines from the window frame.
    private static func viewportLines(_ entry: HistoryEntry) -> Int {
        guard let frame = AX.frame(entry.axWindow) else { return 40 }
        return max(20, Int((frame.height - 100) / 17))
    }

    // ------------------------------------------------------------ plumbing

    /// App's focused element, only if it belongs to the picked window.
    private static func focusedElement(in entry: HistoryEntry) -> AXUIElement? {
        let appEl = AX.application(entry.pid)
        guard let focused = AX.element(appEl, kAXFocusedUIElementAttribute as String)
        else { return nil }
        if let win = AX.element(focused, kAXWindowAttribute as String),
           !entry.sameWindow(as: win) {
            return nil
        }
        return focused
    }

    /// Focused element when it shows text, else the largest text area in the
    /// window that reports a visible range.
    private static func mainTextElement(in entry: HistoryEntry) -> AXUIElement? {
        if let focused = focusedElement(in: entry), visibleRange(of: focused) != nil {
            return focused
        }
        var best: (el: AXUIElement, area: CGFloat)?
        var budget = walkBudget
        walk(entry.axWindow, depth: 0, budget: &budget) { el in
            guard AX.string(el, kAXRoleAttribute as String) == "AXTextArea",
                  visibleRange(of: el) != nil else { return false }
            let frame = AX.frame(el) ?? .zero
            let area = frame.width * frame.height
            if area > (best?.area ?? 0) { best = (el, area) }
            return false // keep walking: want the largest, not the first
        }
        return best?.el
    }

    private static func visibleRange(of el: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                el, kAXVisibleCharacterRangeAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ref as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    /// Depth-first walk; the visitor returns true to stop.
    @discardableResult
    private static func walk(_ el: AXUIElement, depth: Int, budget: inout Int,
                             visit: (AXUIElement) -> Bool) -> Bool {
        guard depth <= 12, budget > 0 else { return false }
        budget -= 1
        if visit(el) { return true }
        for kid in AX.elements(el, kAXChildrenAttribute as String) {
            if walk(kid, depth: depth + 1, budget: &budget, visit: visit) {
                return true
            }
        }
        return false
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return s
    }

    private static func cap(_ s: String) -> String {
        guard s.utf8.count > Config.maxFileBytes else { return s }
        return String(s.prefix(Config.maxFileBytes))
            + "\n\n[... truncated by ContextStack ...]"
    }
}
