import Foundation

/// User-tweakable settings, persisted in UserDefaults.
/// `defaults write cloud.alexrank.ContextStack <key> ...` to change from
/// the command line.
enum Config {
    private static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            "maxEntries": 7,
            "autoPaste": true,
            "smartRanking": true,
            "notifyOnCopy": true,
            "maxFileBytes": 256 * 1024,
            "captureDir": NSHomeDirectory() + "/ContextStack",
            "hotkey": "ctrl+alt+space",
            "archiveRetentionDays": 7,
            "observeClipboard": false,
            "contentLearning": false,
        ])
    }

    /// Number of recent windows shown in the picker.
    static var maxEntries: Int { d.integer(forKey: "maxEntries") }

    /// Press Cmd+V into the frontmost app after a capture lands on the
    /// clipboard, so picking an action pastes directly.
    static var autoPaste: Bool {
        get { d.bool(forKey: "autoPaste") }
        set { d.set(newValue, forKey: "autoPaste") }
    }

    /// Reorder the action chooser by learned pick probability. Picks are
    /// logged for learning even while this is off.
    static var smartRanking: Bool {
        get { d.bool(forKey: "smartRanking") }
        set { d.set(newValue, forKey: "smartRanking") }
    }

    /// Show a notification after each capture.
    static var notifyOnCopy: Bool { d.bool(forKey: "notifyOnCopy") }

    /// Truncate "file contents" captures beyond this many bytes.
    static var maxFileBytes: Int { d.integer(forKey: "maxFileBytes") }

    /// Where captures (markdown/PNG) are written.
    static var captureDir: String {
        d.string(forKey: "captureDir") ?? NSHomeDirectory() + "/ContextStack"
    }

    /// Picker hotkey, e.g. "ctrl+alt+space", "cmd+shift+k", "ctrl+f19".
    static var hotkey: String {
        d.string(forKey: "hotkey") ?? "ctrl+alt+space"
    }

    /// Archived captures older than this are deleted (launch + daily).
    /// 0 = keep forever.
    static var archiveRetentionDays: Int { d.integer(forKey: "archiveRetentionDays") }

    /// Opt-in: learn from manual Cmd+C/Cmd+V (metadata only, never content).
    static var observeClipboard: Bool {
        get { d.bool(forKey: "observeClipboard") }
        set { d.set(newValue, forKey: "observeClipboard") }
    }

    /// Opt-in: topic matching over the capture archive (content the user
    /// already captured — the clipboard is never read for this).
    static var contentLearning: Bool {
        get { d.bool(forKey: "contentLearning") }
        set { d.set(newValue, forKey: "contentLearning") }
    }

    /// Browsers that speak the Chrome AppleScript dictionary
    /// (bundle ID → name to use in `tell application`).
    static let chromiumBundles: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.google.Chrome.canary": "Google Chrome Canary",
        "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
        "company.thebrowser.Browser": "Arc",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    /// Browsers that speak the Safari AppleScript dictionary.
    static let safariBundles: [String: String] = [
        "com.apple.Safari": "Safari",
        "com.apple.SafariTechnologyPreview": "Safari Technology Preview",
    ]

    /// Apps never recorded in the history.
    static let excludeBundles: Set<String> = [
        "cloud.alexrank.ContextStack",
    ]
}

func csLog(_ items: Any...) {
    let msg = items.map { "\($0)" }.joined(separator: " ")
    NSLog("[ContextStack] %@", msg)
}
