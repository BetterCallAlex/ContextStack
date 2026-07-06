---
tags: [module]
module: action-ranking
source: [ContextStackApp/Sources/ContextStack/ActionRanker.swift]
updated: 2026-07-06
---

# action-ranking

**Substrate** ([[LearningCore.swift]]): both heads (and future ones) share
one `PointwiseSoftmaxModel` (hashed features → softmax over presented
candidates → SGD), `EventLogFile` (jsonl append + replay lines) and the
FNV hash / recency decay. A fixed-class head is the pointwise form with
per-class feature offsets — the math exists once.

**Does:** two learned heads. `ActionRanker` reorders the action chooser (top
row = Enter-Enter default); `WindowRanker` moves the picker's preselection
highlight (never the order — recency is muscle memory).

**Why it exists / key decisions:**
- Model: single-layer softmax (online multinomial logistic regression) over
  hashed features (FNV-1a → 4096 dims), one SGD step per pick, lr 0.15.
  Deliberately small: tens–hundreds of events; deep nets would overfit.
- Softmax masked to actions actually presented (sets differ per entry kind).
- Hierarchy encoded in features, not architecture: bias (global) → app ids →
  `tgt×src`, `src×kind` crosses → `src×title-token` (per-project). Unseen
  context backs off smoothly = cold start solved for free.
- **Sequence features** (a1f5aaa): prev pick in 30-min session, prev pick per
  source app (6 h), prev×kind bigram. Pastes cluster in bursts; identical-
  context block-continuation ~82% in selftest vs coin-flip static.
- Event log (`~/Library/Application Support/ContextStack/action-events.jsonl`)
  is source of truth; weights = cache rebuilt by replay at launch → feature
  set can change without losing data. Replay recency-weighted (30-day
  half-life, floor 0.25) so habits can change.
- **Selection as feature, not rule**: `sel`, `sel×src`, `sel×tgt` in both
  heads. Some users select to paste, others to read — the model measures
  which, per app, instead of a static boost. Masking already gave the
  selectedText class a learned prior; these crosses let selection shift the
  *other* actions and the window choice too.
- `WindowRanker` ([[WindowRanker.swift]]): pointwise scorer, single weight
  vector, softmax over presented entries; features src, tgt×src, kind,
  recency-rank bucket (model learns the recency prior's true strength), sel
  crosses. Own log `window-events.jsonl`. Predicts only after ≥20 events and
  a real margin; otherwise highlight stays on most-recent. Predicted row gets
  `· likely` badge.
- **Clipboard observer** ([[ClipboardObserver.swift]], opt-in, default OFF,
  menu toggle): changeCount polling + listen-only Cmd+V tap. Metadata only —
  apps, content shape (type/chars/lines/code/url/path flags) — content
  inspected in memory, never stored. Own `clipboard-events.jsonl`. Feeds
  `mcopy` features into the window ranker: recently-copied-from app =
  likelier paste source. Self-writes filtered via changeCount marking.
- Picks logged even when `smartRanking` off. No implicit negatives (explicitly
  deferred by Alex).
- `· learned` badge on top row only when ≥5 samples for source app and top ≠
  canonical first.

**Gotchas:**
> [!warning] `ActionID` cases append-only — enum position = weight-matrix
> class index; reordering breaks learned weights.
- Swift `Hasher` is per-process seeded — that's why FNV, never "fix" it.
- `RankContext.targetBundleID` = frontmost app at hotkey (paste target), not
  the source.

**Links:** [[picker]], [[selection-viewport]]

## Changelog
- 2026-07-07 — Both rankers rebuilt on shared LearningCore; verified byte-identical selftest + eval-log output.
- 2026-07-06 — Opt-in clipboard metadata observer; mcopy window features.
- 2026-07-06 — Selection as learned feature in both heads; new WindowRanker
  preselecting the picker highlight. Selftests: sel-flip 100%,
  window-ranker 100%, holds back <20 events.
- 2026-07-06 — Initial note; state as of a744b63.
- 2026-07-05 — Sequence features + recency-weighted replay (a1f5aaa).
- 2026-07-01 — First version: static context features (6627071).
