---
tags: [module]
module: build-release
source: [ContextStackApp/build-app.sh, ContextStackApp/make-dmg.sh, .github/workflows/release.yml, ContextStackApp/Sources/ContextStack/IconKit.swift]
updated: 2026-07-06
---

# build-release

**Does:** SwiftPM binary → signed .app → optional /Applications install →
.dmg → GitHub release on tag.

**Why it looks like this:**
- [[build-app.sh]] assembles + signs in **/tmp staging**, not the repo:
  iCloud-synced folders (repo lives on Desktop) stamp
  `com.apple.FinderInfo`/fileprovider xattrs that codesign rejects as
  "detritus" once Resources/ is non-empty. `install` mode copies with
  `ditto --noextattr` — plain `cp` drags xattrs into /Applications and fails
  strict verify. Always `./build-app.sh install`, never manual cp.
- **Icon is code** ([[IconKit.swift]]): fanned context-cards mark, coral
  gradient. `.icns` rendered at build time via the binary's own
  `--render-icon` + `iconutil`; menu-bar icon drawn at runtime as template.
  Repo carries no binary image assets (docs/ screenshots excepted).
- [[make-dmg.sh]]: app + /Applications symlink, UDZO. No Developer ID / no
  notarization → downloaders hit Gatekeeper once ("Open Anyway" documented in
  release notes and README).
- CI ([[release.yml]]): push tag `v*` → macos-15 runner builds dmg, runs
  ranker/doc/remote selftests as release gate, `gh release create`. v0.2.0
  worked first try.

**Gotchas:**
- `security find-identity` empty on CI → ad-hoc dmg build; fine (Gatekeeper
  caveat applies regardless).
- Version = `CFBundleShortVersionString` in Resources/Info.plist; dmg name
  derives from it.

**Links:** [[permissions-signing]]

## Changelog
- 2026-07-06 — Initial note; state as of a744b63.
- 2026-07-03 — dmg + release workflow (a089268); staging/xattr hardening,
  install mode (259b051).
