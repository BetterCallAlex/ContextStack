# ContextStack

Snappy "recent windows → context for AI chats" picker for macOS. Standalone
menu-bar app, no dependencies.

You're chatting with Claude (desktop app or Claude Code) and need something you
just had on screen — a web page, a PDF, a code file, a window. Instead of
alt-tabbing, selecting, copying, tabbing back: press **⌃⌥Space**, pick the
window from a list of your last-visited ones, pick *what* to grab, and it's
pasted right where you were typing (and archived in `~/ContextStack/`).

```
⌃⌥Space ──► [ Safari    — Anthropic Docs        browser tab · 2m ago ]
            [ Zed       — main.rs — projectW    document    · 5m ago ]
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
- **It learns your habits.** The action chooser reorders itself around what
  you actually pick per paste-target, source app and project/site — an
  on-device online model, nothing leaves the machine (see
  [ContextStackApp/README.md](ContextStackApp/README.md#learned-action-ranking)).
- **Best available capture per app type**, degrading gracefully:

  | Entry type | Best capture | How | Fallback |
  |---|---|---|---|
  | Browser tab (Safari/Chrome/Arc/Brave/Edge/Vivaldi) | Rendered page text or full HTML — including logged-in pages / SPAs | JavaScript executed in the tab via Apple Events | Plain HTTP fetch of the URL (`textutil` → text) |
  | Browser tab | URL as markdown link | AppleScript tab lookup (finds the tab by remembered title, even if you switched tabs since) | — |
  | Document app (Preview, TextEdit, Xcode, Zed, many others) | The file itself: path, `@path` for Claude Code, or contents | Accessibility `AXDocument`, focused-element ancestors, path/filename in the window title + Spotlight | Screenshot |
  | Zed over SSH | Remote file contents | Remote root → host from Zed's session db, then `ssh host cat` | Path only |
  | Any window | Window screenshot | ScreenCaptureKit; legacy CGWindowList path for windows on other Spaces | — |
  | Any window | Visible text (best effort) | Accessibility tree walk (`AXStaticText`/`AXTextArea` values) | Screenshot |

## Install

Needs macOS 14+ and the Xcode command-line tools (`xcode-select --install`).

```sh
git clone https://github.com/BetterCallAlex/ContextStack.git
cd ContextStack/ContextStackApp
./make-signing-cert.sh     # one-time, keeps permission grants across rebuilds
./build-app.sh install
open /Applications/ContextStack.app
```

The setup window opens on first launch and walks through every permission
with live status. Build details, config, debug tooling and troubleshooting:
[ContextStackApp/README.md](ContextStackApp/README.md).

## Permissions (the "is this even allowed?" answer)

macOS supports this pattern explicitly — it's how Raycast, Alfred and window
managers work. **No blanket screen recording of everything is needed.**

| Capability | API | Permission (System Settings → Privacy & Security) | When asked |
|---|---|---|---|
| Track which window is focused, read titles | Accessibility API | **Accessibility** → enable ContextStack | First launch |
| Read tab URL/title, run JS in a tab | Apple Events | **Automation** → ContextStack → each browser | First time you capture from that browser |
| Window screenshots | ScreenCaptureKit | **Screen Recording** → enable ContextStack | First screenshot action |
| Document path of a window | Accessibility (`AXDocument`) | covered by Accessibility | — |

Notes:

- The setup window (menu-bar icon → *Permissions & Setup…*) shows live status
  for every grant, triggers the prompts, and can reset stale grants.
- Screen Recording is only used by the two screenshot actions; all text, URL
  and file captures work without it. macOS re-confirms the grant periodically.
- For the best browser capture (rendered page text of logged-in pages), enable
  **Allow JavaScript from Apple Events** once per browser:
  - Chrome/Brave/Edge/Arc: menu bar → View → Developer → *Allow JavaScript
    from Apple Events*
  - Safari: Settings → Advanced → *Show features for web developers*, then
    Develop menu → *Allow JavaScript from Apple Events*
  - If you skip this, ContextStack silently falls back to fetching the URL
    over HTTP (fine for public pages, no session/login).

## Usage

1. Work normally. ContextStack remembers your last ~7 focused windows.
2. In Claude (or anywhere), press **⌃⌥Space**.
3. Pick a window (type to filter, Enter to select). The window you're
   currently in is excluded — it's your paste target.
4. Pick a capture action. The first row is the smart default — learned from
   your history once there's some — so **Enter-Enter** grabs the right thing.
5. Done — the capture is pasted into the window you started from
   automatically (toggle *Auto-paste after capture* in the menu-bar menu to
   paste yourself). Every capture is also archived in `~/ContextStack/`
   (`.md` with a source header, or `.png`), so Claude Code can also read it
   by path — the "Screenshot → file path" and "@-reference" actions copy the
   path instead of the content.

Config via `defaults` (see [ContextStackApp/README.md](ContextStackApp/README.md#config)):
`maxEntries`, `captureDir`, `autoPaste`, `smartRanking`, `notifyOnCopy`,
`maxFileBytes`.

## Known limitations

- **Firefox** has no AppleScript tab dictionary → no URL/page-text capture;
  screenshot and window-text still work. Fix: the browser-extension companion
  (roadmap).
- **Electron apps** (Slack, Discord, …) expose patchy Accessibility trees →
  "window text" may come back thin; use the screenshot action.
- A closed window can only be captured via its URL (browsers) or document
  path; minimized windows may resist screenshots.
- Tab matching is by remembered title; if the title changed since you left the
  tab (e.g. an SPA navigation), capture falls back to the browser's currently
  active tab.
- Zed-over-SSH file contents need key-based auth for that host (`ssh` runs in
  BatchMode and never prompts).

## Roadmap

- **Browser-extension companion** (MV3 + native messaging): exact tab
  identity, full DOM without the JS-from-Apple-Events toggle, Firefox support.
- **Prefetch on focus**: capture URL/title asynchronously at focus time so
  entries survive closed tabs.
- **Pinned entries & multi-select**: batch several contexts into one paste.
- **OCR for screenshots** (Apple Vision) so image captures also yield text.

## License

[MIT](LICENSE)
