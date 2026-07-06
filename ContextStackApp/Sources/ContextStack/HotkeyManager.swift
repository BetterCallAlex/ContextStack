import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon RegisterEventHotKey — no permissions needed.
final class HotkeyManager {
    var onHotkey: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    struct Spec: Equatable {
        let keyCode: UInt32
        let carbonModifiers: UInt32
        /// For the menu item: key-equivalent char (empty if unrepresentable)
        /// and Cocoa modifier flags.
        let keyEquivalent: String
        let cocoaModifiers: NSEvent.ModifierFlags
    }

    private static let keyCodes: [String: (code: Int, equivalent: String)] = {
        var m: [String: (Int, String)] = [
            "space": (kVK_Space, " "), "return": (kVK_Return, "\r"),
            "enter": (kVK_Return, "\r"), "tab": (kVK_Tab, "\t"),
            "escape": (kVK_Escape, "\u{1b}"), "delete": (kVK_Delete, ""),
            "up": (kVK_UpArrow, ""), "down": (kVK_DownArrow, ""),
            "left": (kVK_LeftArrow, ""), "right": (kVK_RightArrow, ""),
            "comma": (kVK_ANSI_Comma, ","), "period": (kVK_ANSI_Period, "."),
            "slash": (kVK_ANSI_Slash, "/"), "semicolon": (kVK_ANSI_Semicolon, ";"),
            "quote": (kVK_ANSI_Quote, "'"), "backslash": (kVK_ANSI_Backslash, "\\"),
            "minus": (kVK_ANSI_Minus, "-"), "equal": (kVK_ANSI_Equal, "="),
            "grave": (kVK_ANSI_Grave, "`"),
        ]
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C),
            ("d", kVK_ANSI_D), ("e", kVK_ANSI_E), ("f", kVK_ANSI_F),
            ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I),
            ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L),
            ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R),
            ("s", kVK_ANSI_S), ("t", kVK_ANSI_T), ("u", kVK_ANSI_U),
            ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
            ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z),
        ]
        for (name, code) in letters { m[name] = (code, name) }
        let digits: [(String, Int)] = [
            ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2),
            ("3", kVK_ANSI_3), ("4", kVK_ANSI_4), ("5", kVK_ANSI_5),
            ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8),
            ("9", kVK_ANSI_9),
        ]
        for (name, code) in digits { m[name] = (code, name) }
        let fkeys: [(String, Int)] = [
            ("f1", kVK_F1), ("f2", kVK_F2), ("f3", kVK_F3), ("f4", kVK_F4),
            ("f5", kVK_F5), ("f6", kVK_F6), ("f7", kVK_F7), ("f8", kVK_F8),
            ("f9", kVK_F9), ("f10", kVK_F10), ("f11", kVK_F11), ("f12", kVK_F12),
            ("f13", kVK_F13), ("f14", kVK_F14), ("f15", kVK_F15), ("f16", kVK_F16),
            ("f17", kVK_F17), ("f18", kVK_F18), ("f19", kVK_F19),
        ]
        for (name, code) in fkeys { m[name] = (code, "") }
        return m
    }()

    /// "ctrl+alt+space" → Spec. Nil for unknown keys or empty modifiers
    /// (a bare key as global hotkey would swallow normal typing).
    static func parse(_ spec: String) -> Spec? {
        let parts = spec.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let keyName = parts.last,
              let key = keyCodes[keyName] else { return nil }
        var carbon: UInt32 = 0
        var cocoa: NSEvent.ModifierFlags = []
        for mod in parts.dropLast() {
            switch mod {
            case "ctrl", "control": carbon |= UInt32(controlKey); cocoa.insert(.control)
            case "alt", "opt", "option": carbon |= UInt32(optionKey); cocoa.insert(.option)
            case "cmd", "command": carbon |= UInt32(cmdKey); cocoa.insert(.command)
            case "shift": carbon |= UInt32(shiftKey); cocoa.insert(.shift)
            default: return nil
            }
        }
        guard carbon != 0 else { return nil }
        return Spec(keyCode: UInt32(key.code), carbonModifiers: carbon,
                    keyEquivalent: key.equivalent, cocoaModifiers: cocoa)
    }

    /// The active binding (for menu display).
    private(set) var activeSpec: Spec?

    /// Register from a config string; invalid specs fall back to the default
    /// with an audible complaint rather than leaving the app hotkey-less.
    func register(spec specString: String) {
        var spec = Self.parse(specString)
        if spec == nil {
            Delivery.failure("ContextStack",
                             "Invalid hotkey \"\(specString)\" — using ctrl+alt+space")
            spec = Self.parse("ctrl+alt+space")
        }
        guard let spec else { return }
        activeSpec = spec
        register(keyCode: spec.keyCode, modifiers: spec.carbonModifiers)
    }

    /// Default: ⌃⌥Space.
    func register(keyCode: UInt32 = UInt32(kVK_Space),
                  modifiers: UInt32 = UInt32(controlKey | optionKey)) {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { mgr.onHotkey?() }
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)

        let hkID = EventHotKeyID(signature: 0x4353_544B /* CSTK */, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            csLog("hotkey registration failed:", status)
        }
    }
}
