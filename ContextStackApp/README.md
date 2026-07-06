# ContextStack.app

Standalone Swift menu-bar app. One SwiftPM package, AppKit + SwiftUI,
macOS 14+, no dependencies.

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

Press **⌃⌥Space**: recent-windows picker → capture actions → clipboard +
`~/ContextStack/` archive → **auto-pasted** into the window you started from
(toggle *Auto-paste after capture* in the menu-bar menu to turn that off).

## Architecture

| Concern | Implementation |
|---|---|
| Focus history | `NSWorkspace.didActivateApplicationNotification` + one `AXObserver` per app (`kAXFocusedWindowChangedNotification`) — `FocusTracker.swift` |
| Hotkey | Carbon `RegisterEventHotKey` (⌃⌥Space) — `HotkeyManager.swift` |
| Picker UI | Borderless **non-activating** `NSPanel` (search field + table). Non-activating is what keeps the target window focused so auto-paste lands right — `ChooserPanel.swift` |
| Browser capture | AppleScript via `NSAppleScript` (tab lookup by remembered title, JS execution in the tab); HTTP fallback via `URLSession` + `textutil` — `BrowserCapture.swift` |
| Document path | Layered resolver — `DocumentCapture.swift`: AXDocument on the window, AXDocument on the focused element's ancestors, absolute-path token in the title, then filename-in-title → Spotlight (`mdfind`) ranked by the remaining title tokens. "File contents" falls back to AX window text when nothing resolves (terminals) |
| Remote files | Per-editor resolvers (Zed db, VS Code/Cursor titles + `state.vscdb`, JetBrains options XML) + `ssh` find/cat — `RemoteFileCapture.swift` |
| Window text | AX tree walk (depth ≤ 12, ≤ 3000 nodes) — `AXTextCapture.swift` |
| Selection & viewport | "Selected text" (AXSelectedText via focused element or bounded walk; detected at prewarm, re-read live at capture) and "Visible excerpt" (`AXVisibleCharacterRange` + parameterized `AXStringForRange`, so big buffers never cross the process boundary) — `SelectionCapture.swift`. Zed exposes no text through AX, so its excerpt comes from the session db instead: `scroll_top_row` for the buffer + a window-height viewport estimate, sliced from the file (local read or SSH). Failures beep (`Delivery.failure`) so they're audible even without the notification permission. The user's selection and scroll position are the relevance signals — no camera, no ML |
| Screenshot | **ScreenCaptureKit** `SCScreenshotManager` for on-screen windows; SCWindow matched to the AX window by pid + title, falling back to pid + frame. Windows on another Space or minimized use the legacy `CGWindowListCreateImage` path — SCK's window filter hard-aborts (SkyLight assert) on off-screen windows — `ScreenshotCapture.swift` |
| Auto-paste | `CGEvent` Cmd+V posted to the HID tap — `Delivery.swift` |
| Onboarding | SwiftUI setup window with live permission status, signature diagnostics and stale-grant reset — `Onboarding.swift`, `Permissions.swift` |
| Action ranking | Online softmax model over hashed context features — `ActionRanker.swift` |

## Remote files over SSH (Zed, VS Code, Cursor, JetBrains)

Editors working over SSH only point at *remote* paths, so a local read can't
work. Each supported editor leaves enough breadcrumbs on disk to resolve
(host, remote path) — `RemoteFileCapture.swift`:

- **Zed**: AXDocument carries the remote path; Zed's session database
  (`~/Library/Application Support/Zed/db/*-stable/db.sqlite`) maps remote
  worktree roots to SSH connections. Longest-prefix root wins → exact path.
- **VS Code / Cursor** (+ Insiders, VSCodium): the window title carries
  `[SSH: host]` and the filename; the editor's `state.vscdb` history lists
  `vscode-remote://ssh-remote+…` folder URIs (plain, `user@host:port`, and
  hex-JSON authorities all handled) giving the remote roots. The file is
  located with `find` over SSH (shortest hit wins), then fetched. If
  AXDocument ever carries the `vscode-remote://` URI directly, that wins
  and skips the search.
- **JetBrains** remote development: `ssh://user@host:port/path` project URIs
  from the options XMLs under `~/Library/Application Support/JetBrains/`,
  matched to the window title's project name; filename located like above.

All fetches run `ssh` in BatchMode (never prompts — key auth required, hosts
from your `~/.ssh/config` work), with connect/total timeouts, a size cap and
a binary sniff. The action shows as "File contents (over SSH)"; when the
exact path isn't known upfront there's also "File path (over SSH)".

Debug helpers (no GUI): `--remote-selftest` (parser fixtures),
`--remote-test <remote-path>` (Zed resolution + fetch),
`--remote-find-test <host> <filename> [root]` (find-then-fetch),
`--diag <app> <outfile>` dumps AX + ScreenCaptureKit state (run via
`open -n -W ... --args` so TCC grants apply); `--shot-test <app>` exercises
the production screenshot path.

> Deep engineering docs (decisions, gotchas, per-feature notes) live in
> [`docs/`](../docs/index.md) — one note per feature, kept current on every
> feature commit.

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

On top of the static context, the model sees **sequence features**: the
previous pick within a 30-minute session, the previous pick for the same
source app, and previous-pick × entry-kind bigrams — pastes cluster in
bursts, and the model rides the burst (in the selftest, block continuation
in an *identical* context scores ~80% where a static model coin-flips).
Replay is recency-weighted (30-day half-life), so old habits fade as new
ones form.

Optional extra signal: *Learn from manual copy/paste* (menu toggle, off by
default) observes Cmd+C/Cmd+V **metadata only** — apps involved and content
shape, never the content itself — so an app you just copied from ranks
higher as a source. Events live in `clipboard-events.jsonl`; delete to
forget, toggle off to stop.

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

Via `defaults` (domain `cloud.alexrank.ContextStack`):

```sh
defaults write cloud.alexrank.ContextStack hotkey -string "cmd+shift+k"  # default: ctrl+alt+space
defaults write cloud.alexrank.ContextStack maxEntries -int 10
defaults write cloud.alexrank.ContextStack autoPaste -bool false     # default: true
defaults write cloud.alexrank.ContextStack smartRanking -bool false  # default: true
defaults write cloud.alexrank.ContextStack notifyOnCopy -bool false
defaults write cloud.alexrank.ContextStack captureDir -string "$HOME/SomewhereElse"
defaults write cloud.alexrank.ContextStack maxFileBytes -int 524288
defaults write cloud.alexrank.ContextStack archiveRetentionDays -int 30  # default 7; 0 = keep forever
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
