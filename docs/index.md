---
tags: [index]
docs_path: docs
last_documented_commit: d2bd692
last_documented: 2026-07-06
---

# ContextStack — docs

One-line: macOS menu-bar app; ⌃⌥Space grabs recent-window content (text, files,
screenshots, remote files) and pastes it where you type. Repo = SwiftPM app in
`ContextStackApp/`.

## Features
- [[picker]] — hotkey, focus history, two-stage chooser, snappiness
- [[action-ranking]] — on-device model ordering the action list
- [[browser-capture]] — tab text/HTML/link via Apple Events
- [[document-resolution]] — which file is this window about (layered)
- [[remote-ssh]] — file contents from SSH editors (Zed, VS Code, Cursor, JetBrains)
- [[selection-viewport]] — selected text + visible excerpt ("relevant lines")
- [[screenshots]] — ScreenCaptureKit + other-Space fallback
- [[delivery]] — clipboard, auto-paste, archive, failure feedback
- [[permissions-signing]] — TCC identity, local cert, onboarding
- [[build-release]] — build script, icon pipeline, dmg, CI

## Dev
- [[dev-tools]] — CLI selftests and live-diagnosis flags

## Conventions
- Vault = repo root. Docs in `docs/`. Style: `living-docs` skill.
- After committing feature changes: reconcile these notes + changelog line,
  bump `last_documented_commit` above (see repo `CLAUDE.md`).
