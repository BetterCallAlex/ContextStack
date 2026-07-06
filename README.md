<p align="center">
  <img src="docs/logo.png" width="140" alt="ContextStack logo">
</p>

<h1 align="center">ContextStack</h1>

<p align="center">
  <b>⌃⌥Space — grab what you just had on screen, pasted where you're typing.</b><br>
  A macOS menu-bar app for feeding context to AI chats.
</p>

---

You're chatting with Claude (desktop app or Claude Code) and need something
you just looked at — a web page, a PDF, a code file, a terminal. Instead of
alt-tabbing, selecting, copying, tabbing back: press **⌃⌥Space**, pick the
window, pick what to grab. It's pasted right where you were typing.

<p align="center"><img src="docs/picker.png" width="680" alt="Recent-windows picker"></p>

**Stack it:** press Tab in the picker to mark several windows — Enter
captures them all and pastes one combined markdown document. With Apple
Intelligence available, the stack offers **"Summarize, then paste"**: the
on-device model condenses it to the essentials (identifiers and error lines
kept verbatim) before pasting — the full stack is archived alongside.

Pick a window, and ContextStack offers the best captures for what it is —
with the most likely one already on top, so **Enter-Enter** usually does it:

<p align="center"><img src="docs/actions.png" width="580" alt="Capture actions for a Zed SSH file"></p>

## What it can grab

| Source | Captures |
|---|---|
| **Browser tab** (Safari, Chrome, Arc, Brave, Edge, Vivaldi) | Rendered page text or full HTML — including logged-in pages and SPAs — via JavaScript in the tab; URL as a markdown link. Falls back to fetching the URL. |
| **Document window** (Preview, TextEdit, Xcode, Zed, …) | The file itself: contents, path, or `@path` for Claude Code. Resolved via Accessibility, window title, or Spotlight. |
| **Remote files over SSH** (Zed, VS Code, Cursor, JetBrains) | Remote file contents — ContextStack works out host and path from the editor's own session data or window title and fetches with `ssh`. |
| **Any window** | Screenshot (pasteable image + saved PNG) — works even for windows on other Spaces — visible text via Accessibility, or **OCR** — the window's pixels read as text, for apps Accessibility can't see into. |
| **The relevant lines** | Text you *selected* (offered on top when a selection exists), the **visible excerpt** (what's scrolled into view), or the **relevant excerpt** — a scored slice: error lines, your uncommitted git edits, on-topic sections. Its size adapts to your feedback. |

Every capture also lands in `~/ContextStack/` as a timestamped `.md`/`.png`
with a source header, so Claude Code can read it by path.

## It learns what you paste

The action list reorders itself around your habits: a tiny on-device model
(online softmax over context features) learns which capture you pick per
paste target, per app, and per project or site — one Zed project can settle
on `@-reference` while another prefers screenshots. It also rides your
bursts (five screenshots in a row means the sixth is already on top),
treats a quick re-pick as a correction, and highlights the *window* you're
likely to pick next — recency order stays untouched, only the preselection
moves. Recent habits outweigh old ones.

Two opt-in signals go further (both off by default, menu toggles): **manual
copy/paste metadata** (which apps you copy from and paste into — shape flags
only, never content) and **topic matching** (embeddings over your own
capture archive, so the window matching what you're currently working on
ranks higher). Everything stays on your machine; delete a log file to
forget, toggle off to stop.

## Small conveniences that add up

- **Recent Captures** in the menu re-copies any of your last ten captures.
- The archive expires itself (`archiveRetentionDays`, default 7; 0 keeps
  forever).
- Browser tabs are remembered at focus time — a tab you closed (or a browser
  you quit) can still yield its link and page text.
- The hotkey is yours: `defaults write cloud.alexrank.ContextStack hotkey
  -string "cmd+shift+k"`.

## Privacy, by construction

**Pointers, not recordings.** The history holds only window references,
titles and timestamps. Content is read at the moment you pick an entry —
never in the background, no database of your screen.

## Install

**Download:** grab the `.dmg` from
[Releases](https://github.com/BetterCallAlex/ContextStack/releases) and drag
ContextStack to Applications. On first launch macOS blocks apps from
unidentified developers (the build isn't notarized) — approve once under
System Settings → Privacy & Security → *Open Anyway*.

**Or build from source** — locally signed, no Gatekeeper step. Needs
macOS 14+ and the Xcode command-line tools (`xcode-select --install`).

```sh
git clone https://github.com/BetterCallAlex/ContextStack.git
cd ContextStack/ContextStackApp
./make-signing-cert.sh     # one-time: lets permission grants survive rebuilds
./build-app.sh install
open /Applications/ContextStack.app
```

The setup window opens on first launch: live status for each permission,
one-click prompts, and a reset for grants gone stale.

<p align="center"><img src="docs/setup.png" width="620" alt="Setup window with live permission status"></p>

ContextStack uses the same permission model as Raycast or Alfred:
**Accessibility** (window tracking, auto-paste), **Automation** per browser
(tab capture), and **Screen Recording** only for the screenshot actions. For
logged-in pages, enable *Allow JavaScript from Apple Events* in your browser
once — the setup window shows how; without it, page capture falls back to a
plain URL fetch.

Build internals, config knobs, debug tooling, troubleshooting:
[ContextStackApp/README.md](ContextStackApp/README.md).

## Limitations

- **Firefox**: no AppleScript tab dictionary → no URL/page-text capture
  (screenshot and window text still work).
- **Electron apps** expose patchy accessibility trees → "window text" may be
  thin; use the screenshot action.
- SSH file contents need key-based auth for that host (never prompts).

## Roadmap

Browser-extension companion (exact tab identity, Firefox) · pinned entries ·
LLM tags as ranking features once they earn their weight on real usage.

## License

[MIT](LICENSE)
