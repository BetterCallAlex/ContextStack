---
tags: [module]
module: delivery
source: [ContextStackApp/Sources/ContextStack/Delivery.swift]
updated: 2026-07-06
---

# delivery

**Does:** capture result → clipboard → auto-paste → `~/ContextStack/` archive
→ notification.

**Why it looks like this:**
- Clipboard is the universal interface — works into Claude app, Claude Code,
  anything. Text goes as markdown with a small source header; images as real
  NSImage objects.
- `autoPaste` default **true** (Alex: pick action → pasted, no manual Cmd+V).
  Synthetic Cmd+V via CGEvent to the HID tap; works because the chooser panel
  is non-activating — target app kept focus the whole time.
- **`autoPasteDelay` = 0.12 s** between clipboard write and keystroke. Not
  waiting for content (delivery fires on fetch completion) — it cushions
  pasteboard-server propagation vs. target read, the user's physical Enter
  still being down, and panel teardown. Failure mode it prevents = pasting
  the *previous* clipboard; worst possible bug here. No API exists to observe
  "target can see new clipboard".
- Archive + notification moved off critical path (359a7eb): clipboard+paste
  first, file write async behind.
- `failure()` **beeps** then notifies — notifications are an optional
  permission; silence must never mask a failed capture (a744b63).
- `suppressAutoPaste` flag for CLI test modes — a test capture must not paste
  into whatever the user has focused.

**Gotchas:**
- Notifications require a real .app bundle (`Bundle.main.bundleIdentifier`
  guard) — `swift run` gets logs only.

**Links:** [[picker]], [[screenshots]]

## Changelog
- 2026-07-06 — Initial note; state as of a744b63. failure() beep (a744b63).
- 2026-07-05 — Delay 250→120 ms; async archive (359a7eb).
