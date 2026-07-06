# ContextStack — agent instructions

## Documentation (mandatory on committed changes)

`docs/` is a living-docs vault (one note per feature, `docs/index.md` is the
map; style: dense fragments, why > what, ≤60 lines per note). **Whenever you
commit a feature change or bug fix:**

1. Reconcile the affected note(s) in `docs/` — fix stale claims in place,
   don't append duplicates. New feature → new note from the existing pattern.
2. Add one dated changelog line per touched note (what + why + commit).
3. Bump `last_documented_commit` + `last_documented` in `docs/index.md` —
   always in a separate follow-up commit, never via `--amend` (amending
   changes the hash the marker just recorded).

Docs describe decisions and gotchas, not code restated. The commit message
carries the why — put it in the note too.

## Conventions

- Feature work happens on a `feature/*` branch; merge to `main` on Alex's
  word, push only when asked.
- Build/install: `ContextStackApp/build-app.sh install` (never manual `cp` —
  see `docs/build-release.md`).
- After code changes run the selftests:
  `.build/debug/ContextStack --ranker-selftest | --doc-selftest | --remote-selftest`.
- Live/permission-dependent testing: `open -n -W /Applications/ContextStack.app
  --args <flag>` — see `docs/dev-tools.md`.
- `ActionID` enum cases are append-only (learned-weight class indices).
