---
tags: [module]
module: selection-viewport
source: [ContextStackApp/Sources/ContextStack/SelectionCapture.swift]
updated: 2026-07-06
---

# selection-viewport

**Does:** "the relevant lines, not the whole file" — two capture actions from
direct attention signals. No ML, no camera (eye tracking evaluated and
rejected: webcam gaze ≈ 2–4° error, never line-level; viewport/selection are
character-precise and free).

**Selected text:**
- Selection = user's own statement of relevance → canonical top action when
  present, with inline preview in the row.
- Detected at prewarm (focused-element read everywhere; bounded tree walk for
  non-browsers — selections persist in background AppKit windows; browsers
  skip the walk, web trees too big). Capture re-reads live, snapshot fallback.

**Visible excerpt:**
- `AXVisibleCharacterRange` of main text area (focused element if text-bearing,
  else largest `AXTextArea`), extracted via parameterized `AXStringForRange` —
  big editor buffers never cross the process boundary.
- **Zed path** (a744b63): Zed exposes zero text via AX. Its session db records
  `scroll_top_row` per buffer → slice resolved file (local read or
  [[remote-ssh]] fetch) from that row for one window-height estimate
  (~17 px/line). Source labeled `path#Lstart-end`. Scroll row persisted
  periodically by Zed → may lag live scrolling slightly.
- Action gated: only offered when AX text view exists or Zed path can serve —
  no dead menu rows.
- Fallback chain: AX → Zed session → window-text walk → beeping failure.

**Gotchas:**
> [!warning] AX ranges count UTF-16 units, Swift counts graphemes — the
> non-parameterized fallback substring can drift on emoji-heavy text.
- Electron apps: patchy AX trees; excerpt often unavailable → gate hides it.

**Links:** [[remote-ssh]], [[delivery]], [[action-ranking]]

## Changelog
- 2026-07-06 — Zed session-db excerpt + gating + audible failures (a744b63);
  initial actions (5bcc18a). Verified live: Terminal excerpt = exact on-screen
  buffer; Zed scroll row reads correctly.
