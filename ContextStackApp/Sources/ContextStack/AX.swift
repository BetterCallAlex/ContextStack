import AppKit
import ApplicationServices

/// Thin helpers over the C Accessibility API.
enum AX {
    /// Cap for AX IPC into other processes. The system default is 6 seconds
    /// per call — one busy Electron app would freeze the picker for that
    /// long. Snappiness beats completeness here.
    static let messagingTimeout: Float = 0.2

    /// App element with the bounded messaging timeout applied.
    static func application(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, messagingTimeout)
        return el
    }
    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
              let s = v as? String else { return nil }
        return s
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
              let arr = v as? [AnyObject] else { return [] }
        return arr.compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        }
    }

    static func pid(_ el: AXUIElement) -> pid_t? {
        var p: pid_t = 0
        guard AXUIElementGetPid(el, &p) == .success else { return nil }
        return p
    }

    /// Window frame in global top-left-origin coordinates (same space as
    /// CGWindowList / ScreenCaptureKit frames).
    static func frame(_ win: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// Focused window of the frontmost application, if readable.
    static func frontmostFocusedWindow() -> AXUIElement? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        return element(application(front.processIdentifier),
                       kAXFocusedWindowAttribute as String)
    }
}
