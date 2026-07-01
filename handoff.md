# HANDOFF — ContextStack debugging session (macOS)

> **Addendum (2026-07-01):** two changes since this was written.
> 1. `autoPaste` now defaults to **true** (spoon + docs): picking an action
>    pastes directly, no manual Cmd+V.
> 2. The roadmap item "standalone Swift menu-bar app" is built:
>    `ContextStackApp/` (SwiftPM, macOS 14+, compiles clean, launches, not yet
>    permission-tested end-to-end — needs the grants from its setup window).
>    See `ContextStackApp/README.md`. The spoon test checklist below still
>    applies to *both* implementations; neither has been verified against real
>    browsers/permissions yet.

You are picking up a freshly built, **never-run-on-macOS** MVP. Your job:
get it running on this Mac, fix whatever breaks, and verify each capture
path. Read this file fully before touching code.

## What this is

ContextStack = "recent windows → context for AI chats" picker for macOS,
built as a Hammerspoon Spoon. Alex works with the Claude desktop app /
Claude Code and wants to stop manually alt-tab-copy-pasting context
(web pages, PDFs, windows). Flow:

1. A window-focus tracker remembers the last ~7 focused windows
   (pointers only: window ref, app, bundle ID, title, timestamp —
   nothing is captured in the background).
2. Hotkey **⌃⌥Space** → `hs.chooser` picker of those windows (current
   window excluded — it's the paste target).
3. Picking one shows a second chooser with capture actions; the result
   goes to the clipboard AND is archived in `~/ContextStack/`.
4. User pastes into Claude with Cmd+V (`autoPaste = true` does it for you).

Capture actions by entry type:

- **Browser tab** (Safari + Chromium family: Chrome/Arc/Brave/Edge/Vivaldi):
  - *Page text* / *Full HTML*: AppleScript finds the tab by remembered title
    (fallback: active tab), then runs JS in it (`document.body.innerText` /
    `outerHTML`) — needs "Allow JavaScript from Apple Events" enabled in the
    browser. If JS fails → falls back to `hs.http.asyncGet` of the URL, then
    `textutil -convert txt` for the text variant.
  - *Link (markdown)*: `[title](url)` via the same tab lookup.
- **Document window** (`AXDocument` attribute present — Preview, TextEdit,
  Xcode…): file path / `@path` for Claude Code / file contents (text
  extensions only, 256 KB cap, binary sniff via NUL byte).
- **Any window**: screenshot via `win:snapshot()` (image → clipboard +
  saved PNG, or path-only variant); best-effort text via AX tree walk
  (AXStaticText/AXTextArea/AXTextField values, depth ≤ 12, ≤ 3000 nodes).

## Repo layout

- `ContextStack.spoon/init.lua` — everything (~460 lines). Single file on purpose.
- `examples/init-snippet.lua` — lines for `~/.hammerspoon/init.lua`.
- `install.sh` — copies the spoon into `~/.hammerspoon/Spoons/` and appends
  the snippet if absent. Idempotent-ish (skips if init.lua mentions ContextStack).
- `README.md` — user-facing docs: permission walkthrough, usage, limitations, roadmap.

## Current state / what's verified

Written blind on a headless Linux box (hera). Verified there:
- `luac5.4 -p` syntax check passes (Hammerspoon runs Lua 5.4).
- Spoon loads and `init()`/`show()` run under a stubbed `hs.*` API;
  percent-decoding of `file://` AXDocument URLs tested.

**Nothing has touched real macOS APIs yet.** Expect small breakage.

## Getting started (do this in order)

1. `brew install --cask hammerspoon` (if missing), then `./install.sh`.
2. Launch Hammerspoon → grant **Accessibility** when prompted.
3. Open the Hammerspoon **Console** (menu-bar hammer icon → Console) —
   all spoon logs are prefixed `[ContextStack]`. `hs.reload()` after every
   code edit; edit the installed copy in `~/.hammerspoon/Spoons/` while
   debugging, but **sync fixes back to this repo** when done.
4. Switch between a few apps, press ⌃⌥Space.

## Likely failure points (check in this order)

These are the API assumptions I could not verify — the most probable bugs:

1. **`hs.window.filter.default:subscribe(hs.window.filter.windowFocused, fn)`**
   — verify callback really delivers `(window, appName, event)` and events fire.
   If the default filter is too aggressive about excluding apps, switch to
   `hs.window.filter.new(true)` (slower) or a curated filter.
2. **AppleScript list → Lua**: `resolveTab()` returns `{theURL, theTitle}` from
   AppleScript and the code expects a Lua array (`r[1]`, `r[2]`) from
   `hs.osascript.applescript`. If the conversion differs, simplest fix: return
   `theURL & "\n" & theTitle` and split.
3. **Tab-title matching**: the code matches stored *window* title against *tab*
   titles. On macOS Chrome/Safari the window title should equal the active tab
   title, but **Arc** decorates titles — if lookup always falls through to the
   active-tab fallback, loosen to `contains` matching or strip suffixes.
4. **`hs.pasteboard.writeObjects(img)`** for putting an hs.image on the
   clipboard — if pasting into the Claude app doesn't work, try
   `hs.pasteboard.writeImage` or write the PNG and use AppleScript
   `set the clipboard to (read (POSIX file ...) as «class PNGf»)`.
5. **Chrome `execute javascript`** requires View → Developer → *Allow
   JavaScript from Apple Events* (Safari: Develop menu equivalent). Arc may
   not expose the toggle — then the HTTP-fetch fallback should kick in
   silently; verify it does.
6. **`hs.axuielement.windowElement(win)`** + `AXDocument` — verify with a PDF
   open in Preview. Also `collectAXText` on an Electron app could be slow —
   if the UI hitches, lower the depth/node budget.
7. **Chooser chaining**: the action chooser opens 0.05 s after the main one
   closes; if it doesn't appear or loses keyboard focus, bump the delay.
   Custom keys on choices (`uuid`, `idx`) must survive the callback round-trip.
8. **Snapshot permission**: first screenshot action should trigger the Screen
   Recording prompt for Hammerspoon (Sequoia re-confirms periodically).

## Test checklist (definition of done)

- [ ] History fills; picker shows entries with app icons; current window excluded
- [ ] Safari: page text, link, full HTML (with JS toggle on AND off — fallback path)
- [ ] Chrome or Arc: same three
- [ ] Preview + PDF: file path, @-reference; a .md/.txt file: file contents
- [ ] Any window: screenshot → clipboard pastes as image into Claude app
- [ ] Screenshot → file path usable in Claude Code
- [ ] Window text on a native app (e.g. Notes) returns something sane
- [ ] Captures archived in `~/ContextStack/` with source headers
- [ ] `autoPaste = true` mode works end-to-end into the Claude app

## Config knobs

In the spoon table: `maxEntries` (7), `captureDir` (`~/ContextStack`),
`autoPaste` (false), `notifyOnCopy` (true), `maxFileBytes` (256 KB),
`chromiumBundles` / `safariBundles` (bundle-ID → AppleScript app name),
`excludeBundles`. Hotkey via `bindHotkeys({ show = ... })` in the snippet.

## After it works (roadmap, don't start unless asked)

Browser-extension companion (exact tab identity, full DOM without the JS
toggle, Firefox); prefetch URL on focus so closed tabs survive; pinned
entries / multi-select; OCR for screenshots; standalone Swift menu-bar app.

## Housekeeping

- Origin of this repo: built on hera (`/home/alex/context-stack`); Alex's git
  server is Forgejo at `git.alexrank.cloud` (user `alex`) if you need a remote.
- Keep README.md truthful: if you change behavior or discover a limitation is
  wrong, update it in the same commit.
