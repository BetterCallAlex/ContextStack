---
tags: [module]
module: action-ranking
source: [ContextStackApp/Sources/ContextStack/ActionRanker.swift]
updated: 2026-07-06
---

# action-ranking

**Does:** reorders the action chooser by predicted pick probability; top row =
Enter-Enter default.

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
- 2026-07-06 — Initial note; state as of a744b63.
- 2026-07-05 — Sequence features + recency-weighted replay (a1f5aaa).
- 2026-07-01 — First version: static context features (6627071).
