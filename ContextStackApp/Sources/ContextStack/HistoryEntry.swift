import AppKit
import ApplicationServices

/// One remembered window. A pointer, not a recording: AX reference, app,
/// title, timestamp. Content is captured only when the user picks an action.
final class HistoryEntry {
    let axWindow: AXUIElement
    let pid: pid_t
    let appName: String
    let bundleID: String
    let title: String
    var time: Date

    init(axWindow: AXUIElement, pid: pid_t, appName: String, bundleID: String, title: String) {
        self.axWindow = axWindow
        self.pid = pid
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.time = Date()
    }

    func sameWindow(as other: AXUIElement) -> Bool {
        CFEqual(axWindow, other)
    }

    var appIcon: NSImage? {
        if let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon {
            return icon
        }
        if !bundleID.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    var agoText: String {
        let d = Int(-time.timeIntervalSinceNow)
        if d < 60 { return "\(d)s ago" }
        if d < 3600 { return "\(d / 60)m ago" }
        return "\(d / 3600)h ago"
    }

    // --------------------------------------------------- entry resolution

    private static let resolveQueue = DispatchQueue(
        label: "cloud.alexrank.ContextStack.resolve", qos: .userInitiated)
    private static let resolutionTTL: TimeInterval = 20
    private var resolutionCache: (value: EntryResolution, at: Date)?
    private var prewarming = false

    /// Prefetched browser-tab metadata (URL + title, no content) — filled
    /// in the background while the action chooser is open.
    var cachedTab: (url: String, title: String, at: Date)?

    func cachedResolution() -> EntryResolution? {
        guard let c = resolutionCache,
              Date().timeIntervalSince(c.at) < Self.resolutionTTL else { return nil }
        return c.value
    }

    /// Resolve synchronously (main thread), served from the cache when the
    /// prewarm already did the work.
    func resolution() -> EntryResolution {
        if let cached = cachedResolution() { return cached }
        let r = EntryResolution.compute(for: self)
        resolutionCache = (r, Date())
        return r
    }

    /// Kick resolution onto a background queue at picker-open time so the
    /// result is ready by the time the user picks this entry. AX calls are
    /// bounded by AX.messagingTimeout, so even a stalled source app can't
    /// freeze anything for long.
    func prewarmResolution() {
        guard cachedResolution() == nil, !prewarming else { return }
        prewarming = true
        Self.resolveQueue.async { [weak self] in
            guard let self else { return }
            let r = EntryResolution.compute(for: self)
            DispatchQueue.main.async {
                self.resolutionCache = (r, Date())
                self.prewarming = false
            }
        }
    }
}

/// Everything the action chooser needs to know about an entry, computed in
/// one pass (browser check short-circuits all AX/db work).
struct EntryResolution {
    let isBrowser: Bool
    let doc: String?
    let remote: RemoteFileCapture.Candidate?
    let titleCandidate: DocumentCapture.TitleCandidate?
    /// Snapshot of the window's text selection at prewarm time — presence
    /// gates the "Selected text" action; the capture re-reads live.
    let selection: String?

    var kind: String {
        if isBrowser { return "browser tab" }
        if doc != nil || remote != nil || titleCandidate != nil { return "document" }
        return "window"
    }

    static func compute(for entry: HistoryEntry) -> EntryResolution {
        if BrowserCapture.family(of: entry) != nil {
            // Browsers: skip doc/AX tree work, but a selection in the page
            // is still the strongest capture signal (focused-element read
            // only — no walks through web content trees).
            let selection = SelectionCapture.selection(in: entry, allowTreeWalk: false)
            return EntryResolution(isBrowser: true, doc: nil, remote: nil,
                                   titleCandidate: nil, selection: selection)
        }
        let doc = DocumentCapture.cheapDocumentPath(entry)
        let remote = RemoteFileCapture.candidate(for: entry, docPath: doc)
        let titleCandidate = (doc != nil || remote != nil)
            ? nil : DocumentCapture.titleCandidate(entry.title)
        let selection = SelectionCapture.selection(in: entry, allowTreeWalk: true)
        return EntryResolution(isBrowser: false, doc: doc, remote: remote,
                               titleCandidate: titleCandidate, selection: selection)
    }
}
