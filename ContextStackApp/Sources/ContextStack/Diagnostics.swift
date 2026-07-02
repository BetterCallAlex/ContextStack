import AppKit
import ApplicationServices
import ScreenCaptureKit

/// `ContextStack --diag <app-name-or-bundle-substring> <output-file>`
///
/// Dumps what the Accessibility tree and ScreenCaptureKit actually expose
/// for the given running app, and attempts a real window capture. Launch it
/// through LaunchServices so it runs with the app's own TCC grants:
///
///     open -n -W /Applications/ContextStack.app --args --diag zed /tmp/diag.txt
enum Diagnostics {
    static func run(appQuery: String, outPath: String) {
        var out: [String] = []
        // Flush on every line: if something aborts the process (e.g. a
        // SkyLight assert inside ScreenCaptureKit), partial output survives.
        func log(_ s: String) {
            out.append(s)
            try? out.joined(separator: "\n").appending("\n")
                .write(toFile: outPath, atomically: true, encoding: .utf8)
        }
        func flushAndExit(_ code: Int32) -> Never {
            exit(code)
        }

        log("=== ContextStack diagnostics \(Date()) ===")
        log("AXIsProcessTrusted: \(AXIsProcessTrusted())")
        log("CGPreflightScreenCaptureAccess: \(CGPreflightScreenCaptureAccess())")

        let q = appQuery.lowercased()
        let matches = NSWorkspace.shared.runningApplications.filter {
            ($0.localizedName ?? "").lowercased().contains(q)
                || ($0.bundleIdentifier ?? "").lowercased().contains(q)
        }
        guard let app = matches.first else {
            log("no running app matching '\(appQuery)'")
            flushAndExit(1)
        }
        log("app: \(app.localizedName ?? "?") pid=\(app.processIdentifier) "
            + "bundle=\(app.bundleIdentifier ?? "?")")

        // ------------------------------------------------------ AX side
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        let windows = AX.elements(appEl, kAXWindowsAttribute as String)
        log("AX windows: \(windows.count)")
        for (i, w) in windows.prefix(3).enumerated() {
            log("window[\(i)] title=\(AX.string(w, kAXTitleAttribute as String) ?? "nil")")
            log("  role=\(AX.string(w, kAXRoleAttribute as String) ?? "nil") "
                + "subrole=\(AX.string(w, kAXSubroleAttribute as String) ?? "nil")")
            log("  AXDocument=\(AX.string(w, "AXDocument") ?? "nil")")
            log("  frame=\(AX.frame(w).map { String(describing: $0) } ?? "nil")")
        }
        if let focused = AX.element(appEl, kAXFocusedUIElementAttribute as String) {
            var el: AXUIElement? = focused
            var hop = 0
            while let cur = el, hop < 8 {
                let value = AX.string(cur, kAXValueAttribute as String)
                log("focused^\(hop): role=\(AX.string(cur, kAXRoleAttribute as String) ?? "?") "
                    + "doc=\(AX.string(cur, "AXDocument") ?? "nil") "
                    + "valueChars=\(value?.count ?? 0)")
                el = AX.element(cur, kAXParentAttribute as String)
                hop += 1
            }
        } else {
            log("no focused element")
        }
        if let w = windows.first {
            var nodes = 0, textNodes = 0, chars = 0
            var roles: [String: Int] = [:]
            var budget = 4000
            func walk(_ el: AXUIElement, depth: Int) {
                guard depth <= 10, budget > 0 else { return }
                budget -= 1
                nodes += 1
                let role = AX.string(el, kAXRoleAttribute as String) ?? "?"
                roles[role, default: 0] += 1
                if role == "AXStaticText" || role == "AXTextArea" || role == "AXTextField",
                   let v = AX.string(el, kAXValueAttribute as String), !v.isEmpty {
                    textNodes += 1
                    chars += v.count
                }
                for kid in AX.elements(el, kAXChildrenAttribute as String) {
                    walk(kid, depth: depth + 1)
                }
            }
            walk(w, depth: 0)
            log("AX walk: nodes=\(nodes) textNodes=\(textNodes) chars=\(chars)")
            log("roles: " + roles.sorted { $0.value > $1.value }.prefix(12)
                .map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }

        // ------------------------------------------------------ SCK side
        var done = false
        Task { @MainActor in
            do {
                let content = try await SCShareableContent
                    .excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let wins = content.windows.filter {
                    $0.owningApplication?.processID == app.processIdentifier
                }
                log("SC windows for pid: \(wins.count)")
                for w in wins.prefix(6) {
                    log("  sc title='\(w.title ?? "nil")' frame=\(w.frame) "
                        + "onScreen=\(w.isOnScreen) layer=\(w.windowLayer)")
                }
                // SCContentFilter(desktopIndependentWindow:) hard-aborts in
                // SkyLight for off-screen windows — never pass one.
                if let target = wins.first(where: { $0.isOnScreen }) {
                    let filter = SCContentFilter(desktopIndependentWindow: target)
                    log("filter contentRect=\(filter.contentRect) "
                        + "scale=\(filter.pointPixelScale)")
                    let cfg = SCStreamConfiguration()
                    cfg.width = max(1, Int(filter.contentRect.width
                                           * CGFloat(filter.pointPixelScale)))
                    cfg.height = max(1, Int(filter.contentRect.height
                                            * CGFloat(filter.pointPixelScale)))
                    cfg.showsCursor = false
                    let img = try await SCScreenshotManager.captureImage(
                        contentFilter: filter, configuration: cfg)
                    log("captured image \(img.width)x\(img.height)")
                } else {
                    log("no on-screen SC window to capture (off-screen ones would abort)")
                }
                // Can the legacy path capture other-Space windows on this OS?
                if let off = wins.first(where: { !$0.isOnScreen && $0.frame.height > 100 }) {
                    let img = ScreenshotCapture.legacyCapture(windowID: off.windowID)
                    log("CGWindowList off-screen capture of '\(off.title ?? "")': "
                        + (img.map { "\($0.width)x\($0.height)" } ?? "nil"))
                }
            } catch {
                log("SCK error: \(error)")
            }
            done = true
        }
        let deadline = Date().addingTimeInterval(15)
        while !done, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        if !done { log("SCK timed out after 15s") }
        flushAndExit(0)
    }
}
