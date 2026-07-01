import AppKit
import ApplicationServices

/// Keeps the recent-windows history. NSWorkspace tells us when an app is
/// activated; an AXObserver per app tells us when the focused window changes
/// within that app. Equivalent of hs.window.filter windowFocused subscription.
final class FocusTracker {
    static let shared = FocusTracker()

    private(set) var history: [HistoryEntry] = []
    private var observers: [pid_t: AXObserver] = [:]

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appActivated(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        if let front = NSWorkspace.shared.frontmostApplication {
            noteFocusedWindow(of: front)
            installObserver(for: front)
        }
        csLog("focus tracking started")
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        installObserver(for: app)
        // The focused window is often not settled at activation time.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.noteFocusedWindow(of: app)
        }
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        observers.removeValue(forKey: app.processIdentifier)
    }

    private func noteFocusedWindow(of app: NSRunningApplication) {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard let win = AX.element(appEl, kAXFocusedWindowAttribute as String) else { return }
        record(windowElement: win)
    }

    private func installObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier,
              observers[pid] == nil else { return }
        var observer: AXObserver?
        let cb: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue()
            tracker.record(windowElement: element)
        }
        guard AXObserverCreate(pid, cb, &observer) == .success, let observer else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, appEl,
                                  kAXFocusedWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(observer),
                           .defaultMode)
        observers[pid] = observer
    }

    fileprivate func record(windowElement win: AXUIElement) {
        guard let pid = AX.pid(win), pid != ProcessInfo.processInfo.processIdentifier
        else { return }
        guard AX.string(win, kAXRoleAttribute as String) == (kAXWindowRole as String)
        else { return }
        if let subrole = AX.string(win, kAXSubroleAttribute as String),
           subrole != (kAXStandardWindowSubrole as String), subrole != (kAXDialogSubrole as String) {
            return
        }
        let app = NSRunningApplication(processIdentifier: pid)
        let bundleID = app?.bundleIdentifier ?? ""
        if Config.excludeBundles.contains(bundleID) { return }

        let entry = HistoryEntry(
            axWindow: win,
            pid: pid,
            appName: app?.localizedName ?? "?",
            bundleID: bundleID,
            title: AX.string(win, kAXTitleAttribute as String) ?? ""
        )
        history.removeAll { $0.sameWindow(as: win) }
        history.insert(entry, at: 0)
        // Keep a few spares beyond maxEntries: the frontmost window is
        // excluded at picker time.
        while history.count > Config.maxEntries + 3 {
            history.removeLast()
        }
    }

    /// Entries for the picker: newest first, current focused window excluded
    /// (it is the paste target), capped at maxEntries.
    func pickerEntries() -> [HistoryEntry] {
        let focused = AX.frontmostFocusedWindow()
        var out: [HistoryEntry] = []
        for e in history {
            if let f = focused, e.sameWindow(as: f) { continue }
            out.append(e)
            if out.count >= Config.maxEntries { break }
        }
        return out
    }
}
