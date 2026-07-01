# ContextStack.app — standalone Swift menu-bar app

Same product as the Hammerspoon spoon, no Hammerspoon dependency. One SwiftPM
package, AppKit + SwiftUI, macOS 14+.

## Build & install

```sh
cd ContextStackApp
./build-app.sh
cp -R build/ContextStack.app /Applications/
open /Applications/ContextStack.app
```

First launch opens the **Setup window**: live status for every permission with
Request / Open Settings buttons. Grant **Accessibility** (required), then
optionally Screen Recording (screenshots), Automation per browser (tab
captures; the prompt only fires while that browser is running) and
Notifications. Reopen the window anytime from the menu-bar icon →
*Permissions & Setup…*.

Press **⌃⌥Space** — same flow as the spoon: recent-windows picker → capture
actions → clipboard + `~/ContextStack/` archive → **auto-pasted** into the
window you started from (toggle *Auto-paste after capture* in the menu-bar
menu to turn that off).

## Architecture (maps 1:1 to the spoon)

| Concern | Spoon (Hammerspoon) | This app |
|---|---|---|
| Focus history | `hs.window.filter` windowFocused | `NSWorkspace.didActivateApplicationNotification` + one `AXObserver` per app (`kAXFocusedWindowChangedNotification`) — `FocusTracker.swift` |
| Hotkey | `hs.hotkey` | Carbon `RegisterEventHotKey` (⌃⌥Space) — `HotkeyManager.swift` |
| Picker UI | `hs.chooser` | Borderless **non-activating** `NSPanel` (search field + table). Non-activating is what keeps the target window focused so auto-paste lands right — `ChooserPanel.swift` |
| Browser capture | AppleScript via `hs.osascript` | Same AppleScript via `NSAppleScript`; HTTP fallback via `URLSession` + `textutil` — `BrowserCapture.swift` |
| Document path | `hs.axuielement` `AXDocument` | Raw AX C API — `DocumentCapture.swift`, `AX.swift` |
| Window text | AX tree walk | Same walk (depth ≤ 12, ≤ 3000 nodes) — `AXTextCapture.swift` |
| Screenshot | `hs.window:snapshot()` | **ScreenCaptureKit** `SCScreenshotManager`; SCWindow matched to the AX window by pid + title, falling back to pid + frame — `ScreenshotCapture.swift` |
| Auto-paste | `hs.eventtap.keyStroke` | `CGEvent` Cmd+V posted to the HID tap — `Delivery.swift` |
| Onboarding | README walkthrough | SwiftUI setup window with live permission status — `Onboarding.swift`, `Permissions.swift` |

## Config

Same knobs as the spoon, via `defaults` (domain `cloud.alexrank.ContextStack`):

```sh
defaults write cloud.alexrank.ContextStack maxEntries -int 10
defaults write cloud.alexrank.ContextStack autoPaste -bool false   # default: true
defaults write cloud.alexrank.ContextStack notifyOnCopy -bool false
defaults write cloud.alexrank.ContextStack captureDir -string "$HOME/SomewhereElse"
defaults write cloud.alexrank.ContextStack maxFileBytes -int 524288
```

Browser bundle-ID tables live in `Sources/ContextStack/Config.swift`.

## Signing / TCC caveat

`build-app.sh` signs ad-hoc when `CODESIGN_IDENTITY` is unset. macOS ties
permission grants to the code signature, so after a rebuild the OS may ask
again (or need a remove-and-re-add in System Settings). For a stable setup,
either rebuild rarely and re-grant, or set `CODESIGN_IDENTITY` to a real
signing identity. Always run the copy in `/Applications`, not the one in
`build/` — moving the binary after granting also invalidates grants.
