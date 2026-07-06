---
tags: [module]
module: picker
source: [ContextStackApp/Sources/ContextStack/]
updated: 2026-07-06
---

# picker

**Does:** ⌃⌥Space → recent-windows list → capture actions for the picked one.

**Why it exists / key decisions:**
- History = pointers only (AX window ref, app, title, timestamp). Content read
  at pick time, never in background — the product's privacy contract.
- Chooser is a borderless **non-activating** `NSPanel` — target app never
  loses focus, so auto-paste lands where the hotkey was pressed.
- Current focused window excluded from list — it's the paste target.
- Frontmost app at hotkey = paste target; captured before showing picker,
  strongest ranking signal for [[action-ranking]].

**Shape:**
- [[FocusTracker.swift]] — NSWorkspace activation + one AXObserver per app
  (`kAXFocusedWindowChangedNotification`); keeps `maxEntries+3` entries
- [[HotkeyManager.swift]] — Carbon `RegisterEventHotKey`, no permissions
- [[ChooserPanel.swift]] — Spotlight-style panel; search field + table
- [[PickerFlow.swift]] — two stages, action list assembly
- [[HistoryEntry.swift]] — entry + `EntryResolution` cache/prewarm

**Snappiness (deliberate, measured):**
- No delay between stages; panel stays up across stage switch (`finish()` runs
  callback first, orders out only if callback didn't re-`show()`).
- `EntryResolution` (doc/remote/selection/kind) computed once, cached 20 s,
  **prewarmed on background queue at picker open** — pick time = cache read.
- AX messaging timeout 0.2 s (system default 6 s) on every element we touch;
  one stalled Electron app must not freeze the picker.
- Row kind labels come from cache, bundle-based fallback when cold (cosmetic).

**Gotchas:**
- Zed publishes no AX windows list; only focused-window attr works.
- Window subrole filter: only `AXStandardWindow`/`AXDialog` recorded.

**Links:** [[action-ranking]], [[delivery]]

**Action icons:** one SF Symbol per method (`ActionID.symbolName` in
[[PickerFlow.swift]]); variants override (SSH fetch → `network`, Spotlight
locate → `magnifyingglass`). Template-tinted, no drawn assets.

## Changelog
- 2026-07-06 — SF Symbol per action row; variant overrides for SSH/Spotlight.
- 2026-07-06 — Window preselection: learned highlight ([[WindowRanker.swift]]),
  recency order untouched; `· likely` badge on predicted row (0a0e257).
- 2026-07-06 — Initial note; state as of a744b63.
- 2026-07-05 — Prewarm/caching, AX timeouts, no stage delay (db10678); tab +
  SC-content prefetch at action-open (359a7eb).
