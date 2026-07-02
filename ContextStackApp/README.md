# ContextStack.app — standalone Swift menu-bar app

Same product as the Hammerspoon spoon, no Hammerspoon dependency. One SwiftPM
package, AppKit + SwiftUI, macOS 14+.

## Build & install

```sh
cd ContextStackApp
./make-signing-cert.sh     # one-time: stable signing identity (see Signing below)
./build-app.sh install     # build, sign, install to /Applications
open /Applications/ContextStack.app
```

`./build-app.sh` without `install` just produces `build/ContextStack.app`.
The script assembles and signs in `/tmp` and installs with
`ditto --noextattr` — both deliberate: iCloud-synced folders (Desktop,
Documents) stamp xattrs on files that codesign rejects as "detritus", and
plain `cp` would carry them into `/Applications`.

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
| Screenshot | `hs.window:snapshot()` | **ScreenCaptureKit** `SCScreenshotManager` for on-screen windows; SCWindow matched to the AX window by pid + title, falling back to pid + frame. Windows on another Space or minimized use the legacy `CGWindowListCreateImage` path — SCK's window filter hard-aborts (SkyLight assert) on off-screen windows — `ScreenshotCapture.swift` |
| Auto-paste | `hs.eventtap.keyStroke` | `CGEvent` Cmd+V posted to the HID tap — `Delivery.swift` |
| Onboarding | README walkthrough | SwiftUI setup window with live permission status — `Onboarding.swift`, `Permissions.swift` |

## Remote files (Zed over SSH)

Zed publishes the *remote* path in AXDocument for SSH projects
(`/home/user/project/file.py`), so a local read can't work. ContextStack
matches that path against the SSH workspaces recorded in Zed's session
database (`~/Library/Application Support/Zed/db/*-stable/db.sqlite`, read
immutable/read-only), picks the connection whose worktree root is the longest
prefix, and runs `ssh <host> cat -- <path>` (BatchMode, 6 s connect / 15 s
total timeout, size cap, binary sniff) — `RemoteFileCapture.swift`. Works
with hosts from your `~/.ssh/config`; key-based auth required (BatchMode
never prompts). The action shows as "File contents (over SSH)".

Debug helpers (no GUI): `--remote-test <remote-path>` resolves and fetches;
`--diag <app> <outfile>` dumps AX + ScreenCaptureKit state for an app (run
via `open -n -W ... --args` so TCC grants apply); `--shot-test <app>`
exercises the production screenshot path.

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

## The mark

Three rounded "context cards" fanned like a hand of cards, the top one tilted
with two text lines — a piece of context being picked up. Coral gradient tile
for the app icon; the menu bar shows the same fan as a monochrome template
image. Everything is drawn in code (`IconKit.swift`): the `.icns` is rendered
at build time (`ContextStack --render-icon <dir>` + `iconutil`), the menu-bar
icon at runtime — the repo carries no binary image assets. To tweak the
design, edit `IconKit.swift` and rebuild; `--render-icon` also writes
`preview.png` / `preview-menubar.png` for a quick look.

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

## Signing / TCC (the "grants don't stick" trap)

macOS ties every permission grant to the exact code signature. An ad-hoc
signature changes on every rebuild, which silently invalidates old grants:
System Settings still shows the toggle as on, but the running app gets
nothing, and flipping the toggle does **not** help (it never re-captures the
signature). The fix is a *stable* signing identity:

```sh
./make-signing-cert.sh   # one-time: self-signed cert "ContextStack Local Signing"
./build-app.sh           # picks the cert up automatically from then on
```

Expect one password dialog (trust settings) during cert creation and possibly
a "codesign wants to access key" dialog on the first build → Always Allow.
With the stable identity, grants survive rebuilds.

If grants ever go stale anyway (e.g. builds made before the cert existed),
use **Reset stale grants** in the setup window — it runs
`tccutil reset Accessibility|ScreenCapture|AppleEvents` for the app's bundle
ID — then re-grant and relaunch. The setup window footer shows how the
running binary is signed. Always run the copy in `/Applications`, not the one
in `build/` — moving the binary after granting also invalidates grants; use
`./build-app.sh install` when updating.
