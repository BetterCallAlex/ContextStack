import AppKit
import ApplicationServices

/// Best-effort visible-text extraction: walk the window's accessibility tree
/// and collect AXStaticText/AXTextArea/AXTextField values.
enum AXTextCapture {
    private static let maxDepth = 12

    private static func collect(_ el: AXUIElement, into acc: inout [String],
                                depth: Int, budget: inout Int) {
        guard depth <= maxDepth, budget > 0 else { return }
        budget -= 1
        if let role = AX.string(el, kAXRoleAttribute as String),
           role == "AXStaticText" || role == "AXTextArea" || role == "AXTextField" {
            if let v = AX.string(el, kAXValueAttribute as String), !v.isEmpty {
                acc.append(v)
            }
        }
        for kid in AX.elements(el, kAXChildrenAttribute as String) {
            collect(kid, into: &acc, depth: depth + 1, budget: &budget)
        }
    }

    static func captureWindowText(_ entry: HistoryEntry) {
        var acc: [String] = []
        var budget = 3000
        collect(entry.axWindow, into: &acc, depth: 0, budget: &budget)
        let text = acc.joined(separator: "\n")
        if !text.isEmpty {
            Delivery.text(entry: entry, kind: "window text (Accessibility)",
                          source: entry.appName, content: text)
        } else {
            Delivery.notify("ContextStack",
                            "No text found via Accessibility — try the screenshot action instead")
        }
    }
}
