import SwiftUI
import UserNotifications

/// Setup window: live status of every permission plus buttons that trigger
/// the system prompts / open the right System Settings pane.
enum Onboarding {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: OnboardingView())
        let w = NSWindow(contentViewController: hosting)
        w.title = "ContextStack Setup"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.setContentSize(NSSize(width: 640, height: 720))
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct StatusDot: View {
    let ok: Bool?

    var body: some View {
        Circle()
            .fill(ok == true ? Color.green : (ok == false ? Color.red : Color.orange))
            .frame(width: 10, height: 10)
    }
}

private struct PermissionRow<Buttons: View>: View {
    let title: String
    let detail: String
    let ok: Bool?
    let statusText: String
    @ViewBuilder let buttons: Buttons

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusDot(ok: ok).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(statusText).font(.caption).bold()
                    .foregroundColor(ok == true ? .green : .primary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) { buttons }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

private struct OnboardingView: View {
    @State private var axOK = Permissions.accessibilityGranted
    @State private var srOK = Permissions.screenRecordingGranted
    @State private var browserStatuses: [String: Permissions.AutomationStatus] = [:]
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined
    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private let installedBrowsers: [(bundleID: String, name: String)] =
        Config.chromiumBundles.merging(Config.safariBundles) { a, _ in a }
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.key) != nil }
            .map { (bundleID: $0.key, name: $0.value) }
            .sorted { $0.name < $1.name }

    private func refresh() {
        axOK = Permissions.accessibilityGranted
        srOK = Permissions.screenRecordingGranted
        for b in installedBrowsers {
            browserStatuses[b.bundleID] = Permissions.automationStatus(bundleID: b.bundleID)
        }
        Permissions.notificationStatus { notifStatus = $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("ContextStack Setup").font(.title).bold()
                Text("ContextStack needs a few one-time permissions. Nothing is captured "
                     + "in the background — content is read only when you pick a window "
                     + "in the ⌃⌥Space picker.")
                    .font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                PermissionRow(
                    title: "Accessibility (required)",
                    detail: "Tracks which window is focused, reads window titles and "
                        + "document paths, and presses Cmd+V for auto-paste.",
                    ok: axOK,
                    statusText: axOK ? "Granted" : "Not granted") {
                    Button("Request") { Permissions.requestAccessibility() }
                    Button("Open Settings") {
                        Permissions.openSettings(anchor: "Privacy_Accessibility")
                    }
                }

                PermissionRow(
                    title: "Screen Recording (screenshots only)",
                    detail: "Used only by the two screenshot actions, via ScreenCaptureKit. "
                        + "All text, URL and file captures work without it.",
                    ok: srOK,
                    statusText: srOK ? "Granted" : "Not granted") {
                    Button("Request") { Permissions.requestScreenRecording() }
                    Button("Open Settings") {
                        Permissions.openSettings(anchor: "Privacy_ScreenCapture")
                    }
                }

                Text("Automation — browser captures").font(.headline).padding(.top, 4)
                Text("One grant per browser. The prompt only appears while the browser "
                     + "is running.")
                    .font(.caption).foregroundColor(.secondary)
                ForEach(installedBrowsers, id: \.bundleID) { browser in
                    let status = browserStatuses[browser.bundleID] ?? .unknown
                    PermissionRow(
                        title: browser.name,
                        detail: "Read tab URL/title and run capture JavaScript via Apple Events.",
                        ok: status == .granted ? true : (status == .denied ? false : nil),
                        statusText: status.label) {
                        Button("Request") {
                            Permissions.requestAutomation(bundleID: browser.bundleID)
                        }
                        Button("Open Settings") {
                            Permissions.openSettings(anchor: "Privacy_Automation")
                        }
                    }
                }

                let notifOK: Bool? = notifStatus == .authorized ? true
                    : (notifStatus == .denied ? false : nil)
                PermissionRow(
                    title: "Notifications (optional)",
                    detail: "A small confirmation after each capture.",
                    ok: notifOK,
                    statusText: notifStatus == .authorized ? "Granted"
                        : (notifStatus == .denied ? "Denied" : "Not asked yet")) {
                    Button("Request") { Permissions.requestNotifications() }
                }

                GroupBox("Best browser capture: allow JavaScript from Apple Events") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Without this toggle, page-text capture falls back to plainly "
                             + "fetching the URL (fine for public pages, no login/session).")
                        Text("• Chrome/Brave/Edge/Arc: View → Developer → "
                             + "Allow JavaScript from Apple Events")
                        Text("• Safari: Settings → Advanced → Show features for web "
                             + "developers, then Develop → Allow JavaScript from Apple Events")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                HStack {
                    Spacer()
                    Text("Reopen anytime from the menu-bar icon.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 620, minHeight: 500)
        .onAppear { refresh() }
        .onReceive(timer) { _ in refresh() }
    }
}
