import AppKit

// Before anything else — the CLI modes read Config too.
Config.registerDefaults()

// Startup runs on the main thread; top-level code isn't MainActor-inferred
// in this language mode, so bridge explicitly.
MainActor.assumeIsolated {
    CLIModes.runIfRequested()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
