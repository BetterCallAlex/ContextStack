import AppKit
import ApplicationServices

/// `ContextStack --perf-test <app-query> <out-file>` — times the resolution
/// pipeline that runs between picking a window and the action chooser
/// appearing, against a real running app. Run via `open -n -W ... --args`
/// so Accessibility applies.
enum PerfTest {
    static func run(appQuery: String, outPath: String) {
        var out: [String] = []
        func log(_ s: String) {
            out.append(s)
            try? out.joined(separator: "\n").appending("\n")
                .write(toFile: outPath, atomically: true, encoding: .utf8)
        }
        func measure(_ name: String, iterations: Int = 5, _ block: () -> Void) {
            var times: [Double] = []
            for _ in 0..<iterations {
                let t0 = DispatchTime.now().uptimeNanoseconds
                block()
                times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            let sorted = times.sorted()
            log(String(format: "  %-28@ median %7.2f ms   max %7.2f ms",
                       name as NSString, sorted[sorted.count / 2], sorted.last!))
        }

        log("=== perf test \(Date()) trusted=\(AXIsProcessTrusted())")
        let q = appQuery.lowercased()
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").lowercased().contains(q)
        }) else {
            log("no running app matching \(appQuery)")
            exit(1)
        }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard let win = AX.element(appEl, kAXFocusedWindowAttribute as String) else {
            log("no focused window for \(app.localizedName ?? q)")
            exit(1)
        }
        let entry = HistoryEntry(axWindow: win, pid: app.processIdentifier,
                                 appName: app.localizedName ?? "?",
                                 bundleID: app.bundleIdentifier ?? "",
                                 title: AX.string(win, kAXTitleAttribute as String) ?? "")
        log("app: \(entry.appName)  title: \(entry.title)")

        measure("cheapDocumentPath") {
            _ = DocumentCapture.cheapDocumentPath(entry)
        }
        let doc = DocumentCapture.cheapDocumentPath(entry)
        measure("remote candidate") {
            _ = RemoteFileCapture.candidate(for: entry, docPath: doc)
        }
        measure("titleCandidate") {
            _ = DocumentCapture.titleCandidate(entry.title)
        }
        measure("full pick->actions path") {
            _ = PickerFlow.actionsForPerfTest(entry)
        }
        exit(0)
    }
}
