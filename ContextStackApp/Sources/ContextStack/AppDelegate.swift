import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hotkey = HotkeyManager()
    private var statusItem: NSStatusItem!
    private var cleanupTimer: Timer?
    private var recentItems: [CaptureArchive.Item] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Config.registerDefaults()
        if let dir = UIShots.requestedDir {
            UIShots.run(dir: dir)
            return
        }
        Delivery.ensureDir()
        setupStatusItem()

        FocusTracker.shared.start()
        hotkey.onHotkey = { PickerFlow.showMainPicker() }
        hotkey.register(spec: Config.hotkey)

        let firstRun = !UserDefaults.standard.bool(forKey: "onboardingShown")
        if firstRun || !Permissions.accessibilityGranted {
            UserDefaults.standard.set(true, forKey: "onboardingShown")
            Onboarding.show()
        }

        if Config.observeClipboard { ClipboardObserver.shared.start() }
        CaptureArchive.cleanup()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { _ in
            CaptureArchive.cleanup()
        }
        csLog("launched, capture dir:", Config.captureDir)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = IconKit.menuBarImage()
        statusItem.button?.toolTip = "ContextStack"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let show = NSMenuItem(title: "Show Picker", action: #selector(showPicker),
                              keyEquivalent: hotkey.activeSpec?.keyEquivalent ?? "")
        show.keyEquivalentModifierMask = hotkey.activeSpec?.cocoaModifiers ?? []
        show.target = self
        menu.addItem(show)

        menu.addItem(.separator())

        let paste = NSMenuItem(title: "Auto-paste after capture",
                               action: #selector(toggleAutoPaste), keyEquivalent: "")
        paste.state = Config.autoPaste ? .on : .off
        paste.target = self
        menu.addItem(paste)

        let ranking = NSMenuItem(title: "Smart action ranking (learned)",
                                 action: #selector(toggleSmartRanking), keyEquivalent: "")
        ranking.state = Config.smartRanking ? .on : .off
        ranking.target = self
        menu.addItem(ranking)

        let clipboard = NSMenuItem(title: "Learn from manual copy/paste (metadata only)",
                                   action: #selector(toggleClipboardObserver),
                                   keyEquivalent: "")
        clipboard.state = Config.observeClipboard ? .on : .off
        clipboard.target = self
        menu.addItem(clipboard)

        let content = NSMenuItem(title: "Topic matching from capture content",
                                 action: #selector(toggleContentLearning),
                                 keyEquivalent: "")
        content.state = Config.contentLearning ? .on : .off
        content.target = self
        menu.addItem(content)

        recentItems = CaptureArchive.recent()
        let recentMenu = NSMenu()
        if recentItems.isEmpty {
            let none = NSMenuItem(title: "No captures yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            recentMenu.addItem(none)
        } else {
            for (i, item) in recentItems.enumerated() {
                let mi = NSMenuItem(title: item.menuTitle,
                                    action: #selector(repasteRecent(_:)), keyEquivalent: "")
                mi.tag = i
                mi.target = self
                recentMenu.addItem(mi)
            }
        }
        let recent = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
        recent.submenu = recentMenu
        menu.addItem(recent)

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

    @objc private func toggleSmartRanking() {
        Config.smartRanking.toggle()
    }

    @objc private func toggleContentLearning() {
        Config.contentLearning.toggle()
    }

    @objc private func toggleClipboardObserver() {
        Config.observeClipboard.toggle()
        if Config.observeClipboard {
            ClipboardObserver.shared.start()
        } else {
            ClipboardObserver.shared.stop()
        }
    }

    @objc private func repasteRecent(_ sender: NSMenuItem) {
        guard recentItems.indices.contains(sender.tag) else { return }
        CaptureArchive.repaste(recentItems[sender.tag])
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
