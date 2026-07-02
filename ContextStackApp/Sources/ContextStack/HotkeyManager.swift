import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon RegisterEventHotKey — no permissions needed.
final class HotkeyManager {
    var onHotkey: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

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
