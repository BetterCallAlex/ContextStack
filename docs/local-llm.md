---
tags: [module]
module: local-llm
source: [ContextStackApp/Sources/ContextStack/LocalLLM.swift]
updated: 2026-07-07
---

# local-llm

**Does:** on-device LLM tier via Apple FoundationModels (macOS 26 + Apple
Intelligence). Everything canImport/#available-guarded — absent framework or
disabled AI ⇒ features hide themselves. Nothing leaves the Mac.

**Uses:**
- **Summarize stack**: multi-select assembly now offers "Paste raw" vs
  "Summarize, then paste" (chooser appears only when LLM available; raw
  preselected). Summary ≤~400 words, identifiers/errors kept verbatim;
  archive stores BOTH full stack and summary. LLM failure → beep + raw.
- **Capture tagging** (contentLearning opt-in): background classification
  of archived captures into a closed vocabulary (code, error-log, docs,
  prose, data, config, chat, terminal-output) → `capture-tags.jsonl`.
  Data collection for future ranking features — tags NOT fed to rankers
  yet; they must earn weight via --eval-log once enough data exists.

**Gotchas:**
- 3B model follows closed-vocabulary constraints poorly with naive
  prompts — instructions + prompt both repeat the list, answer primed with
  "Tags:", and the parser drops out-of-vocab tokens anyway.
- `--stack-test` sets `CombinedCapture.forceRawDelivery` — the interactive
  raw-vs-summary chooser would hang a CLI run.
- Live check: `--summarize-test` (exit 0 + SKIP note when AI unavailable).

**Links:** [[picker]], [[action-ranking]], [[delivery]]

## Changelog
- 2026-07-07 — Initial: Summarize stack + tagging pipeline; live-verified
  (333-char summary, vocabulary-clean tags).
