---
tags: [module]
module: screenshots
source: [ContextStackApp/Sources/ContextStack/ScreenshotCapture.swift]
updated: 2026-07-06
---

# screenshots

**Does:** window snapshot → clipboard image (+ archived PNG) or PNG path (for
Claude Code).

**Why it looks like this (fa7f3b4):**
> [!warning] `SCContentFilter(desktopIndependentWindow:)` hard-aborts the
> whole process (SkyLight assert) for windows not on the active Space. The
> picked window is *usually* on another Space — the current one is excluded
> from the picker. This crashed the app silently until guarded.
- ScreenCaptureKit only for `isOnScreen` windows; everything else goes through
  legacy `CGWindowListCreateImage` — deprecated but verified working on
  macOS 26 (full-res other-Space capture through the production path).
- SCWindow ↔ AX window matched by pid + title (current AX title first — tab
  switches rename browser windows), fallback pid + frame (±2 px), fallback
  single candidate. No public windowID bridge between AX and SCK.
- `SCShareableContent` enumeration (~100–300 ms, pure metadata) prefetched at
  action-chooser open, 5 s cache (359a7eb).
- Delivery order: clipboard image + paste first, PNG encode/write async
  behind; path-only variant writes first (path is the payload).

**Gotchas:**
- Minimized windows: both paths can fail → beeping failure, "bring on screen".
- SCK config sized from `filter.contentRect × pointPixelScale`.

**Links:** [[delivery]], [[picker]]

## Changelog
- 2026-07-06 — Initial note; state as of a744b63.
- 2026-07-05 — SC content prefetch + async PNG (359a7eb).
- 2026-07-02 — Off-screen abort guard + legacy fallback (fa7f3b4).
