import AppKit

/// `ContextStack --ui-shots <dir>` — poses the app's real UI with curated
/// demo data and screenshots its own windows (README material). Run via
/// `open -n -W ... --args` so the Screen Recording grant applies. The
/// panels appear on screen for a few seconds.
@MainActor
enum UIShots {
    static var requestedDir: String?

    static func run(dir: String) {
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)

        func appIcon(_ bundleID: String) -> NSImage? {
            guard let url = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        }

        let pickerItems = [
            ChooserItem(text: "Safari — Claude API Reference",
                        subText: "browser tab · 2m ago",
                        image: appIcon("com.apple.Safari"), index: 0),
            ChooserItem(text: "Zed — 01_eda.py — thesis",
                        subText: "document · 5m ago",
                        image: appIcon("dev.zed.Zed"), index: 1),
            ChooserItem(text: "Preview — attention-is-all-you-need.pdf",
                        subText: "document · 12m ago",
                        image: appIcon("com.apple.Preview"), index: 2),
            ChooserItem(text: "Terminal — ~/dev/contextstack",
                        subText: "window · 20m ago",
                        image: appIcon("com.apple.Terminal"), index: 3),
            ChooserItem(text: "Notes — Meeting notes",
                        subText: "window · 1h ago",
                        image: appIcon("com.apple.Notes"), index: 4),
        ]

        let actionItems = [
            ChooserItem(text: "File contents (over SSH)",
                        subText: "Remote file — fetched via your Zed SSH connection  · learned",
                        image: nil, index: 0),
            ChooserItem(text: "@-reference (Claude Code)",
                        subText: "Copy '@/home/alex/thesis/notebooks_own/01_eda.py'",
                        image: nil, index: 1),
            ChooserItem(text: "File path",
                        subText: "Copy the document's path",
                        image: nil, index: 2),
            ChooserItem(text: "Screenshot → clipboard",
                        subText: "Window snapshot as image + saved PNG",
                        image: nil, index: 3),
            ChooserItem(text: "Screenshot → file path",
                        subText: "Snapshot saved as PNG, its path copied (for Claude Code)",
                        image: nil, index: 4),
            ChooserItem(text: "Title line",
                        subText: "Copy 'App — window title' as plain text",
                        image: nil, index: 5),
        ]

        Chooser.shared.show(items: pickerItems, placeholder: "Recent windows…") { _ in }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            capturePanel(to: dir + "/picker.png")
            Chooser.shared.show(items: actionItems,
                                placeholder: "Zed — 01_eda.py — thesis") { _ in }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            capturePanel(to: dir + "/actions.png")
            Onboarding.show()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            if let setup = NSApp.windows.first(where: { $0.title == "ContextStack Setup" }) {
                capture(windowNumber: setup.windowNumber, to: dir + "/setup.png")
            }
            print("ui shots written to \(dir)")
            NSApp.terminate(nil)
        }
    }

    private static func capturePanel(to path: String) {
        if let panel = NSApp.windows.first(where: { $0 is ChooserPanel && $0.isVisible }) {
            capture(windowNumber: panel.windowNumber, to: path)
        }
    }

    private static func capture(windowNumber: Int, to path: String) {
        guard let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(windowNumber),
            [.boundsIgnoreFraming, .bestResolution]) else {
            csLog("ui-shot capture failed for window \(windowNumber)")
            return
        }
        IconKit.writePNG(image, to: URL(fileURLWithPath: path))
    }
}
