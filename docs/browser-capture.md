---
tags: [module]
module: browser-capture
source: [ContextStackApp/Sources/ContextStack/BrowserCapture.swift]
updated: 2026-07-06
---

# browser-capture

**Does:** page text / full HTML / markdown link from Safari + Chromium-family
tabs via Apple Events.

**Why it exists / key decisions:**
- Tab found by **remembered window title** across all windows/tabs (the tab may
  have moved since focus); falls back to active tab. Titles are the only
  cross-referenceable identity AppleScript exposes.
- Preferred capture = JS in the live tab (`document.body.innerText` /
  `outerHTML`) — sees logged-in pages and SPAs. Needs per-browser "Allow
  JavaScript from Apple Events" toggle.
- Silent fallback: plain `URLSession` fetch of the URL + `textutil` HTML→text.
  No session/login, but always works; better than an error.
- Tab **metadata prefetch** (URL+title) fires when the action chooser opens —
  via `osascript` subprocess because `NSAppleScript` isn't thread-safe and
  main-thread execution would jank the chooser. Cached 10 s on the entry.
  Content (JS) is never prefetched — consent boundary is the action pick.

**Closed-tab survival:** tab URL+title also prefetched at *focus* time
(debounced 0.6 s, only when the Automation grant already exists — never a
surprise prompt) into `knownTab`, kept without expiry and carried across
refocuses. Capture order: fresh prefetch → live AppleScript lookup →
`knownTab`; with the browser quit, link + HTTP page fetch still work.
Closed-tab-while-browser-runs still hits the script's active-tab fallback
first (known limitation).

**Shape:** bundle-ID → AppleScript-name maps in [[Config.swift]]
(`chromiumBundles`, `safariBundles`); Safari dialect uses `name of tab` /
`current tab`, Chromium `title of tab` / `active tab`.

**Gotchas:**
- Firefox: no AppleScript tab dictionary → no URL/text capture at all.
- Arc decorates window titles → lookup may fall through to active tab.
- First capture per browser triggers the Automation TCC prompt.

**Links:** [[picker]], [[delivery]], [[permissions-signing]]

## Changelog
- 2026-07-06 — Focus-time prefetch → entries survive closed tabs/quit browser.
- 2026-07-06 — Initial note; state as of a744b63.
- 2026-07-05 — Tab metadata prefetch at chooser open (359a7eb).
