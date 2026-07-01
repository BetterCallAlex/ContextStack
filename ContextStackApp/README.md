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
| Document path | `hs.axuielement` `AXDocument` | Layered resolver — `DocumentCapture.swift`: AXDocument on the window, AXDocument on the focused element's ancestors, absolute-path token in the title, then filename-in-title → Spotlight (`mdfind`) ranked by the remaining title tokens. The Spotlight layer is what makes file actions work for editors without AX document support (Zed); "File contents" falls back to AX window text when nothing resolves (terminals) |
| Window text | AX tree walk | Same walk (depth ≤ 12, ≤ 3000 nodes) — `AXTextCapture.swift` |
| Screenshot | `hs.window:snapshot()` | **ScreenCaptureKit** `SCScreenshotManager`; SCWindow matched to the AX window by pid + title, falling back to pid + frame — `ScreenshotCapture.swift` |
| Auto-paste | `hs.eventtap.keyStroke` | `CGEvent` Cmd+V posted to the HID tap — `Delivery.swift` |
| Onboarding | README walkthrough | SwiftUI setup window with live permission status — `Onboarding.swift`, `Permissions.swift` |

## Learned action ranking

The action chooser reorders itself around your habits: the model predicts
which capture action you'll pick given where you are pasting *to* (frontmost
app at hotkey time), which app the source window belongs to, its entry kind,
and the source window's title tokens — so two projects in the same editor can
learn different defaults (e.g. one Zed project → `@-reference`, another →
screenshot). The top row is the Enter-Enter default; when the learned order
deviates from the canonical one with enough evidence, the top row is marked
`· learned`.

Model: a single-layer softmax network (online multinomial logistic
regression, `ActionRanker.swift`) over hashed sparse features, one SGD step
per pick, softmax masked to the actions actually presented. The
global → per-app → per-project hierarchy is encoded in the features (bias,
app IDs, target×source crosses, source×title-token crosses), so unseen
contexts back off smoothly to app-level and global trends.

Every pick is appended to
`~/Library/Application Support/ContextStack/action-events.jsonl`; the weights
are rebuilt from that log at each launch (the log is the source of truth, the
model just a cache). Nothing leaves the machine. Delete the file to reset
learning; toggle *Smart action ranking* in the menu to disable reordering
(picks are still logged).

Verify the learner without granting any permissions:

```sh
.build/debug/ContextStack --ranker-selftest
```

## Config

Same knobs as the spoon, via `defaults` (domain `cloud.alexrank.ContextStack`):

```sh
defaults write cloud.alexrank.ContextStack maxEntries -int 10
defaults write cloud.alexrank.ContextStack autoPaste -bool false     # default: true
defaults write cloud.alexrank.ContextStack smartRanking -bool false  # default: true
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
