import AppKit

/// Opt-in observation of manual Cmd+C / Cmd+V — **metadata only, never
/// content**. Copies are noticed by polling `NSPasteboard.changeCount`
/// (there is no notification API; every clipboard manager polls); pastes by
/// a listen-only CGEvent tap on Cmd+V (covered by the Accessibility grant).
///
/// Stored per event: apps involved, content *shape* (type, char/line counts,
/// looks-like-code/URL/path flags), timestamp. The string is inspected in
/// memory to compute the shape and immediately discarded. Events append to
/// `clipboard-events.jsonl`; delete the file to forget. Feeds the window
/// ranker: an app you just copied from is a likelier paste source.
final class ClipboardObserver {
    static let shared = ClipboardObserver()

    struct Event: Codable {
        let t: String       // "copy" | "paste"
        let ts: Double
        let app: String     // copy: frontmost at copy; paste: paste target
        let type: String?   // copy only: string | image | file | other
        let chars: Int?
        let lines: Int?
        let code: Bool?
        let url: Bool?
        let path: Bool?
    }

    private var timer: Timer?
    private var eventTap: CFMachPort?
    private var lastChangeCount = NSPasteboard.general.changeCount
    /// changeCounts produced by our own deliveries — not "manual copies".
    private var selfCounts: Set<Int> = []
    /// bundleID → last manual copy time; the ranking signal.
    private(set) var recentCopySources: [String: Date] = [:]
    /// Test hook: receives every event in addition to the log.
    var eventSink: ((Event) -> Void)?

    var tapActive: Bool { eventTap != nil }

    // ------------------------------------------------------------ lifecycle

    func start() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        installTap()
        csLog("clipboard observer started (metadata only)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    /// Delivery calls this after writing the pasteboard itself.
    func noteSelfWrite() {
        selfCounts.insert(NSPasteboard.general.changeCount)
        if selfCounts.count > 64 { selfCounts.removeAll() }
    }

    func recentlyCopied(from bundleID: String, within: TimeInterval = 300) -> Bool {
        guard let at = recentCopySources[bundleID] else { return false }
        return Date().timeIntervalSince(at) < within
    }

    // ----------------------------------------------------------- copy side

    private func poll() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard !selfCounts.contains(count) else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let bundleID = front?.bundleIdentifier ?? ""
        guard bundleID != Bundle.main.bundleIdentifier else { return }

        var type = "other"
        var chars: Int?
        var lines: Int?
        var code: Bool?
        var url: Bool?
        var path: Bool?
        if let s = pb.string(forType: .string) {
            type = "string"
            chars = s.count
            lines = s.split(separator: "\n", omittingEmptySubsequences: false).count
            // Shape only — computed and discarded, never stored.
            let codeMarkers = s.filter { "{};=()<>".contains($0) }.count
            code = chars! > 0 && Double(codeMarkers) / Double(chars!) > 0.02
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            url = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            path = trimmed.hasPrefix("/") || trimmed.hasPrefix("~/")
        } else if pb.canReadObject(forClasses: [NSImage.self], options: nil) {
            type = "image"
        } else if pb.types?.contains(.fileURL) == true {
            type = "file"
        }

        if !bundleID.isEmpty {
            recentCopySources[bundleID] = Date()
        }
        emit(Event(t: "copy", ts: Date().timeIntervalSince1970, app: bundleID,
                   type: type, chars: chars, lines: lines,
                   code: code, url: url, path: path))
    }

    // ---------------------------------------------------------- paste side

    private func installTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, _, event, refcon in
            if let refcon,
               event.getIntegerValueField(.keyboardEventKeycode) == 9, // V
               event.flags.contains(.maskCommand) {
                let observer = Unmanaged<ClipboardObserver>
                    .fromOpaque(refcon).takeUnretainedValue()
                DispatchQueue.main.async { observer.notePaste() }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            csLog("clipboard observer: paste tap unavailable (copy side still active)")
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func notePaste() {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard bundleID != Bundle.main.bundleIdentifier else { return }
        emit(Event(t: "paste", ts: Date().timeIntervalSince1970, app: bundleID,
                   type: nil, chars: nil, lines: nil, code: nil, url: nil, path: nil))
    }

    // ------------------------------------------------------------- logging

    private lazy var logURL: URL? = {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("ContextStack", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("clipboard-events.jsonl")
    }()

    private func emit(_ event: Event) {
        eventSink?(event)
        guard let logURL, let data = try? JSONEncoder().encode(event) else { return }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data("\n".utf8))
        }
    }
}
