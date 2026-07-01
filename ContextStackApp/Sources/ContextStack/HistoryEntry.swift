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
}
