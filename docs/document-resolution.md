---
tags: [module]
module: document-resolution
source: [ContextStackApp/Sources/ContextStack/DocumentCapture.swift]
updated: 2026-07-06
---

# document-resolution

**Does:** answers "which file is this window about?" → gates File path /
@-reference / File contents actions.

**Why layered (97f40fc):** only classic document apps (Preview, TextEdit,
Xcode) publish `AXDocument`; Zed and terminals don't — original
single-attribute gate silently hid all file actions there.

**Resolution order (cheap → expensive):**
1. `AXDocument` on window. Zed puts the **remote** path here for SSH projects
   → see [[remote-ssh]].
2. `AXDocument` on focused element + ≤8 ancestors — only if the element sits
   in the picked window.
3. Absolute path token in title existing on disk (`/…`, `~/…`) — terminals
   showing cwd. Directory results get path/@ref but not contents.
4. Filename token in title (`main.rs — projectW`) → Spotlight `mdfind`,
   ranked by remaining title tokens (project name picks the right repo's
   `main.rs`). Multiple hits with zero hint support → **nil on purpose**;
   wrong file worse than no file. Runs at action execution, async — layers
   1–3 gate the menu.

**Contents read:** extension allow-list (`textExtensions`), NUL sniff for
binary, 256 KB cap (`maxFileBytes`).

**Gotchas:**
- `normalizeDocumentString` survives unencoded `file://` (spaces) — raw
  `URL(string:)` returns nil on those.
- Spotlight layer useless for anything not indexed (network mounts, ~/Library).

**Links:** [[remote-ssh]], [[picker]]

## Changelog
- 2026-07-06 — Initial note; state as of a744b63.
- 2026-07-02 — Layered resolver replaced AXDocument-only gate (97f40fc).
