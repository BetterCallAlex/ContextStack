# ContextStack

Snappy "recent windows → context for AI chats" picker for macOS.

You're chatting with Claude (desktop app or Claude Code) and need something you
just had on screen — a web page, a PDF, a window. Instead of alt-tabbing,
selecting, copying, tabbing back: press **⌃⌥Space**, pick the window from a
list of your last-visited ones, pick *what* to grab, and it lands on your
clipboard (and in `~/ContextStack/`) ready to paste.

```
⌃⌥Space ──► [ Safari    — Anthropic Docs        browser tab · 2m ago ]
            [ Preview   — paper.pdf             document    · 5m ago ]
            [ Terminal  — ssh hera              window      · 9m ago ]
                      │
                      ▼ (pick one)
            [ Page text          ]  ← smart default, just press Enter again
            [ Link (markdown)    ]
            [ Full HTML          ]
            [ Screenshot → clipboard ]
            [ Screenshot → file path ]
                      │
                      ▼
            clipboard + ~/ContextStack/2026…-Safari-Anthropic-Docs.md
                      │
                      ▼
            pasted into Claude automatically
```

## Design principles

- **Pointers, not recordings.** The history holds only lightweight metadata:
  window reference, app, title, timestamp. Content is captured *at the moment
  you pick an entry*, never in the background. Nothing to leak, no Rewind-style
  database, no constant screen capture.
- **Clipboard is the universal interface.** Works with the Claude app, Claude
  Code in a terminal, or anything else. Text captures go on the clipboard as
  markdown with a small source header; screenshots go on as real images (the
  Claude app accepts pasted images) and are also saved as PNG so Claude Code
  can read them by path.
- **Best available capture per app type**, degrading gracefully:

  | Entry type | Best capture | How | Fallback |
  |---|---|---|---|
  | Browser tab (Safari/Chrome/Arc/Brave/Edge/Vivaldi) | Rendered page text or full HTML — including logged-in pages / SPAs | JavaScript executed in the tab via Apple Events | Plain HTTP fetch of the URL (`textutil` → text) |
  | Browser tab | URL as markdown link | AppleScript tab lookup (finds the tab by remembered title, even if you switched tabs since) | — |
  | Document app (Preview, TextEdit, Xcode, many others) | The file itself: path, `@path` for Claude Code, or contents | Accessibility `AXDocument` attribute of the window | Screenshot |
  | Any window | Window screenshot | `hs.window:snapshot()` | — |
  | Any window | Visible text (best effort) | Accessibility tree walk (`AXStaticText`/`AXTextArea` values) | Screenshot |

## Two implementations

- **Hammerspoon spoon** (`ContextStack.spoon/`) — the original MVP. One Lua
  file you can hot-reload and iterate on in seconds; permissions are granted
  to Hammerspoon. [Hammerspoon](https://www.hammerspoon.org/) already solves
  every hard platform problem here — global hotkeys, window-focus events, the
  Spotlight-style chooser UI, clipboard (including images), window snapshots,
  AppleScript execution.
- **Standalone Swift menu-bar app** (`ContextStackApp/`) — same architecture
  (NSWorkspace focus tracking + Accessibility + Apple Events +
  ScreenCaptureKit), no Hammerspoon dependency, with a setup window that shows
  live permission status and triggers each grant. Also learns which capture
  action you pick per paste-target, source app and project/site, and reorders
  the action chooser accordingly (on-device online model, event log in
  Application Support). See
  [ContextStackApp/README.md](ContextStackApp/README.md) for build and
  install. Run one or the other, not both (two ⌃⌥Space bindings would clash).

## Permissions (the "is this even allowed?" answer)

macOS supports this pattern explicitly — it's how Raycast, Alfred and window
managers work. **No blanket screen recording of everything is needed.**

| Capability | API | Permission (System Settings → Privacy & Security) | When asked |
|---|---|---|---|
| Track which window is focused, read titles | Accessibility API | **Accessibility** → enable Hammerspoon | First Hammerspoon launch |
| Read tab URL/title, run JS in a tab | Apple Events | **Automation** → Hammerspoon → each browser | First time you capture from that browser |
| Window screenshots | CGWindowList | **Screen Recording** → enable Hammerspoon | First screenshot action |
| Document path of a window | Accessibility (`AXDocument`) | covered by Accessibility | — |

Notes:

- The table shows the spoon; for the standalone app the grantee is
  **ContextStack** instead of Hammerspoon, and its setup window
  (menu-bar icon → *Permissions & Setup…*) walks through every grant.
- On **macOS Sequoia**, Screen Recording grants are periodically re-confirmed
  by the OS (a monthly-ish dialog). Only the screenshot action needs it; all
  text/URL/file captures work without Screen Recording entirely.
- For the best browser capture (rendered page text of logged-in pages), enable
  **Allow JavaScript from Apple Events** once per browser:
  - Chrome/Brave/Edge/Arc: menu bar → View → Developer → *Allow JavaScript
    from Apple Events*
  - Safari: Settings → Advanced → *Show features for web developers*, then
    Develop menu → *Allow JavaScript from Apple Events*
  - If you skip this, ContextStack silently falls back to fetching the URL
    over HTTP (fine for public pages, no session/login).

## Install

**Standalone app** (recommended — no dependencies beyond Xcode command-line
tools, macOS 14+):

```sh
git clone <this repo> && cd contextstack/ContextStackApp
./make-signing-cert.sh     # one-time, keeps permission grants across rebuilds
./build-app.sh install
open /Applications/ContextStack.app
```

The setup window walks through every permission. Details, config and
troubleshooting: [ContextStackApp/README.md](ContextStackApp/README.md).

**Hammerspoon spoon** (alternative):

```sh
brew install --cask hammerspoon
git clone <this repo> && cd contextstack
./install.sh
```

Then launch Hammerspoon, grant Accessibility, and press **⌃⌥Space**.
The hotkey is one line in `~/.hammerspoon/init.lua` — see
[examples/init-snippet.lua](examples/init-snippet.lua).

## Usage

1. Work normally. ContextStack remembers your last ~7 focused windows.
2. In Claude (or anywhere), press **⌃⌥Space**.
3. Pick a window (type to fuzzy-filter, Enter to select). The window you're
   currently in is excluded — it's your paste target.
4. Pick a capture action. The first row is the smart default, so
   **Enter-Enter** grabs the obvious thing (page text for a browser tab).
5. Done — the capture is pasted into the window you started from
   automatically (no Cmd+V needed; set `autoPaste = false` to paste
   yourself). Every capture is also archived in `~/ContextStack/`
   (`.md` with a source header, or `.png`), so Claude Code can also read it
   by path — the "Screenshot → file path" and "@-reference" actions copy the
   path instead of the content.

Config knobs (in `~/.hammerspoon/init.lua`): `maxEntries`, `captureDir`,
`autoPaste` (on by default: Cmd+V is pressed for you after capture),
`notifyOnCopy`, `chromiumBundles` (add other Chromium browsers by bundle ID).

## Known limitations

- **Firefox** has no AppleScript tab dictionary → no URL/page-text capture;
  screenshot and window-text still work. Fix: the browser-extension companion
  (roadmap).
- **Electron apps** (Slack, Discord, …) expose patchy Accessibility trees →
  "window text" may come back thin; use the screenshot action.
- **Editors without `AXDocument`** (e.g. Zed) and **terminals**: the spoon's
  file actions don't appear for them. The Swift app resolves these with a
  layered fallback (title path token → Spotlight lookup by the filename in
  the title, ranked by project tokens; window text as the last resort) — see
  [ContextStackApp/README.md](ContextStackApp/README.md).
- Window snapshots of minimized/other-Space windows can fail; the picker's
  history keeps windows for a while after you leave them, but a closed window
  can only be captured via its URL (browsers) or document path.
- Tab matching is by remembered title; if the title changed since you left the
  tab (e.g. an SPA navigation), capture falls back to the browser's currently
  active tab.

## Roadmap (v2 candidates)

- **Browser-extension companion** (MV3 + native messaging): exact tab
  identity, full DOM without the JS-from-Apple-Events toggle, Firefox support.
- **Prefetch on focus**: capture URL/title asynchronously at focus time so
  entries survive closed tabs.
- **Pinned entries & multi-select**: batch several contexts into one paste.
- **OCR for screenshots** (Apple Vision via Shortcuts/`osascript`) so image
  captures also yield text.
- ~~Standalone Swift menu-bar app~~ — done, see
  [ContextStackApp/](ContextStackApp/README.md).
