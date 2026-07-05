import AppKit
import UserNotifications

/// Capture delivery: clipboard + archive file in ~/ContextStack + notification
/// + optional auto-paste.
enum Delivery {
    static func ensureDir() {
        try? FileManager.default.createDirectory(
            atPath: Config.captureDir, withIntermediateDirectories: true)
    }

    static func sanitize(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                out.append(ch)
            } else if ch == " " {
                out.append("-")
            }
        }
        if out.isEmpty { out = "untitled" }
        return String(out.prefix(48))
    }

    static func captureName(_ entry: HistoryEntry, ext: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return "\(fmt.string(from: Date()))-\(sanitize(entry.appName + "-" + entry.title)).\(ext)"
    }

    static func saveCapture(basename: String, content: String) -> String? {
        ensureDir()
        let path = Config.captureDir + "/" + basename
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        } catch {
            csLog("saveCapture failed:", error.localizedDescription)
            return nil
        }
    }

    static func setClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Deliver a text capture: clipboard + auto-paste immediately, archive
    /// file + notification off the critical path.
    static func text(entry: HistoryEntry, kind: String, source: String?, content: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let header = "# Context: \(entry.appName) — \(entry.title)\n"
            + "Source: \(source ?? "n/a")\n"
            + "Captured: \(fmt.string(from: Date()))\n\n"
        let full = header + content
        setClipboard(full)
        maybeAutoPaste()
        let basename = captureName(entry, ext: "md")
        let appName = entry.appName
        let title = entry.title
        DispatchQueue.global(qos: .utility).async {
            let path = saveCapture(basename: basename, content: full)
            notify("ContextStack: \(kind) copied",
                   "\(appName) — \(title) (\(content.count) chars)\n"
                   + "Saved: \(path ?? "not saved")")
        }
    }

    /// Failure feedback must not depend on the (optional) notification
    /// permission — beep so silence never masks a failed capture.
    static func failure(_ title: String, _ body: String) {
        DispatchQueue.main.async { NSSound.beep() }
        notify(title, body)
    }

    static func notify(_ title: String, _ body: String) {
        csLog(title, "—", body)
        guard Config.notifyOnCopy else { return }
        // UNUserNotificationCenter only works from a real .app bundle.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let req = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
            center.add(req)
        }
    }

    /// Press Cmd+V into the frontmost app. The chooser panel never activates
    /// this app, so the original window is still focused — the paste lands
    /// where the hotkey was pressed.
    /// Set by CLI test modes so a test capture never pastes into whatever
    /// window happens to be focused.
    static var suppressAutoPaste = false

    /// Margin between clipboard write and the synthetic Cmd+V. The chooser
    /// panel is non-activating, so the target app never lost focus — this
    /// only needs to outlive the panel teardown.
    static let autoPasteDelay: TimeInterval = 0.12

    static func maybeAutoPaste() {
        guard Config.autoPaste, !suppressAutoPaste else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + autoPasteDelay) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let vKey: CGKeyCode = 9
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
            else { return }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}
