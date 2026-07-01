import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hotkey = HotkeyManager()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Config.registerDefaults()
        Delivery.ensureDir()
        setupStatusItem()

        FocusTracker.shared.start()
        hotkey.onHotkey = { PickerFlow.showMainPicker() }
        hotkey.register()

        let firstRun = !UserDefaults.standard.bool(forKey: "onboardingShown")
        if firstRun || !Permissions.accessibilityGranted {
            UserDefaults.standard.set(true, forKey: "onboardingShown")
            Onboarding.show()
        }
        csLog("launched, capture dir:", Config.captureDir)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.stack.3d.up",
                                           accessibilityDescription: "ContextStack")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let show = NSMenuItem(title: "Show Picker", action: #selector(showPicker),
                              keyEquivalent: " ")
        show.keyEquivalentModifierMask = [.control, .option]
        show.target = self
        menu.addItem(show)

        menu.addItem(.separator())

        let paste = NSMenuItem(title: "Auto-paste after capture",
                               action: #selector(toggleAutoPaste), keyEquivalent: "")
        paste.state = Config.autoPaste ? .on : .off
        paste.target = self
        menu.addItem(paste)

        let folder = NSMenuItem(title: "Open Capture Folder",
                                action: #selector(openCaptureFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)

        let setup = NSMenuItem(title: "Permissions & Setup…",
                               action: #selector(showOnboarding), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)

        menu.addItem(.separator())

        if Bundle.main.bundleIdentifier != nil {
            let login = NSMenuItem(title: "Launch at Login",
                                   action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            login.target = self
            menu.addItem(login)
        }

        let quit = NSMenuItem(title: "Quit ContextStack",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func showPicker() {
        PickerFlow.showMainPicker()
    }

    @objc private func toggleAutoPaste() {
        Config.autoPaste.toggle()
    }

    @objc private func openCaptureFolder() {
        Delivery.ensureDir()
        NSWorkspace.shared.open(URL(fileURLWithPath: Config.captureDir))
    }

    @objc private func showOnboarding() {
        Onboarding.show()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            csLog("launch-at-login toggle failed:", error.localizedDescription)
        }
    }
}
