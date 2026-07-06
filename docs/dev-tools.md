---
tags: [concept]
module: dev-tools
source: [ContextStackApp/Sources/ContextStack/]
updated: 2026-07-06
---

# dev-tools

**Does:** CLI modes on the app binary (dispatch + shared rig in [[CLIModes.swift]]) for testing without UI. Selftests are
deterministic (CI release gate); live tools need the app's TCC grants — run
via `open -n -W /Applications/ContextStack.app --args <flag>` (LaunchServices
launch = correct TCC identity; direct exec from a shell is untrusted).

| Flag | What | File |
|---|---|---|
| `--ranker-selftest` | prequential accuracy + burst stickiness + cold start | [[RankerSelfTest.swift]] |
| `--doc-selftest` | title parsing, path tokens, Spotlight ranking + live mdfind | [[DocSelfTest.swift]] |
| `--remote-selftest` | remote-editor parser fixtures (26 checks) | [[RemoteSelfTest.swift]] |
| `--remote-test <path>` | Zed resolution + live ssh fetch | main.swift |
| `--remote-find-test <host> <file> [root]` | live find-then-fetch | main.swift |
| `--selection-test <app> <out>` | live selection/excerpt/hasTextView/Zed scroll row | main.swift |
| `--perf-test <app> <out>` | times the pick→actions pipeline, uncached | [[PerfTest.swift]] |
| `--diag <app> <out>` | AX + SCK ground truth dump for a running app | [[Diagnostics.swift]] |
| `--shot-test <app>` | production screenshot path end-to-end | main.swift |
| `--ui-shots <dir>` | poses real UI with demo data, screenshots itself (README) | [[UIShots.swift]] |
| `--render-icon <dir>` | iconset + previews from IconKit | [[IconKit.swift]] |

**Gotchas:**
- Diagnostics flush per line — SkyLight aborts keep partial output.
- CLI test modes set `Delivery.suppressAutoPaste` — never paste into the
  user's focused window from a test.
- `Config.registerDefaults()` runs at process start; CLI modes read Config
  (maxFileBytes=0 truncation bug lived here once).

**Links:** [[remote-ssh]], [[screenshots]], [[picker]]

## Changelog
- 2026-07-07 — Modes extracted from main.swift into CLIModes (shared entry/pump/out helpers).
- 2026-07-06 — Initial note; state as of a744b63.
