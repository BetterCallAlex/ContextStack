---
tags: [module]
module: remote-ssh
source: [ContextStackApp/Sources/ContextStack/RemoteFileCapture.swift]
updated: 2026-07-06
---

# remote-ssh

**Does:** file contents (and paths) for editors working over SSH — the window
names a path that doesn't exist locally.

**Per-editor breadcrumbs → (host, path):**
| Editor | Path from | Host from |
|---|---|---|
| Zed | `AXDocument` (remote path, exact) | session db `workspaces ⋈ remote_connections`, longest-prefix root |
| VS Code / Cursor / forks | filename in title | `[SSH: host]` in title; roots from `state.vscdb` recently-opened `vscode-remote://` URIs |
| JetBrains | filename in title | `ssh://user@host:port/path` URIs scraped from options XMLs (60 s cache) |

- `Candidate` = exact path **or** filename + search roots; search-based
  editors resolve via bounded remote `find` (maxdepth 8, head -20, shortest
  hit wins) then `cat`.
- vscode-remote authority forms all handled: plain, `user@host:port`,
  percent-encoded `+`, hex-encoded JSON (`{"hostName":…}`).
- A `vscode-remote://` AXDocument URI, if an editor ever provides it,
  short-circuits everything.
- All ssh: BatchMode (never prompts — key auth required), ConnectTimeout 6 s,
  total timeouts, size cap, binary sniff.
- **ControlMaster/ControlPersist=60 multiplexing** (359a7eb): measured
  3.9 s cold → 1.0 s warm on same host. ControlPath `/tmp/contextstack-ssh-%C`.
- Zed db opened `immutable=1` read-only — running Zed's locks irrelevant.
- Also serves [[selection-viewport]]: `zedScrollTopRow(forBufferPath:)` from
  the `editors` table.

**Gotchas:**
- JetBrains resolver is fixture-tested only — no Gateway data existed on this
  machine; first live use may need tweaks.
- Duplicate filenames across roots → shortest path heuristic; title's folder
  name narrows roots when it matches.
- VS Code with no remote history for a host falls back to searching remote
  `$HOME` (bounded, 20 s).

**Links:** [[document-resolution]], [[dev-tools]]

## Changelog
- 2026-07-06 — Initial note; state as of a744b63.
- 2026-07-05 — ssh multiplexing (359a7eb).
- 2026-07-04 — VS Code/Cursor/JetBrains resolvers (5117482).
- 2026-07-02 — Zed via session db + ssh cat; verified live 62.5k chars (fa7f3b4).
