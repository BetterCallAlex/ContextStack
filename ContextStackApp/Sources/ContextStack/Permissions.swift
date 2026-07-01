import AppKit
import ApplicationServices
import UserNotifications

/// Status checks and prompt triggers for every permission the app uses.
enum Permissions {
    // ------------------------------------------------------- Accessibility

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    // ----------------------------------------------------- Screen Recording

    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    static func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    // ------------------------------------------------ Automation (per app)

    enum AutomationStatus {
        case granted, denied, notDetermined, notRunning, unknown

        var label: String {
            switch self {
            case .granted: return "Granted"
            case .denied: return "Denied — enable in System Settings"
            case .notDetermined: return "Not asked yet"
            case .notRunning: return "App not running — launch it, then request"
            case .unknown: return "Unknown"
            }
        }
    }

    private static func withAEDesc<T>(bundleID: String,
                                      _ body: (inout AEAddressDesc) -> T) -> T? {
        var addr = AEAddressDesc()
        let data = Data(bundleID.utf8)
        let created = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSErr in
            AECreateDesc(DescType(typeApplicationBundleID),
                         ptr.baseAddress, data.count, &addr)
        }
        guard created == noErr else { return nil }
        defer { AEDisposeDesc(&addr) }
        return body(&addr)
    }

    static func automationStatus(bundleID: String) -> AutomationStatus {
        let status = withAEDesc(bundleID: bundleID) { addr in
            AEDeterminePermissionToAutomateTarget(&addr, typeWildCard, typeWildCard, false)
        }
        switch status {
        case .some(noErr): return .granted
        case .some(-1743): return .denied          // errAEEventNotPermitted
        case .some(-1744): return .notDetermined   // errAEEventWouldRequireUserConsent
        case .some(-600): return .notRunning       // procNotFound
        default: return .unknown
        }
    }

    /// Trigger the system consent dialog (target app must be running).
    static func requestAutomation(bundleID: String) {
        DispatchQueue.global().async {
            _ = withAEDesc(bundleID: bundleID) { addr in
                AEDeterminePermissionToAutomateTarget(&addr, typeWildCard, typeWildCard, true)
            }
        }
    }

    // -------------------------------------------------------- Notifications

    static func notificationStatus(_ cb: @escaping (UNAuthorizationStatus) -> Void) {
        guard Bundle.main.bundleIdentifier != nil else {
            cb(.denied)
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { cb(settings.authorizationStatus) }
        }
    }

    static func requestNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert]) { _, _ in }
    }

    // ------------------------------------------------------ System Settings

    static func openSettings(anchor: String) {
        let url = "x-apple.systempreferences:com.apple.preference.security?" + anchor
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
