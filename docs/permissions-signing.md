---
tags: [module]
module: permissions-signing
source: [ContextStackApp/Sources/ContextStack/Permissions.swift, ContextStackApp/Sources/ContextStack/Onboarding.swift, ContextStackApp/make-signing-cert.sh]
updated: 2026-07-06
---

# permissions-signing

**Does:** TCC permission lifecycle — status, prompts, and keeping grants alive
across rebuilds.

**The trap this module exists for (fbc33d0):**
> [!warning] macOS ties every TCC grant to the exact code signature. Ad-hoc
> signatures change on every rebuild → grants silently die; System Settings
> still shows the toggle ON, and flipping it does NOT re-capture the
> signature. Only remove+re-add or `tccutil reset` fixes it.
- Fix: one-time self-signed cert **"ContextStack Local Signing"**
  ([[make-signing-cert.sh]]) — constant leaf cert → grants survive rebuilds.
  PEM import (PKCS12 fails against modern keychain). `build-app.sh` picks it
  up automatically; ad-hoc is the warned fallback.
- Setup window ([[Onboarding.swift]]): live status per grant, Request/Open
  Settings buttons, **Reset stale grants** (tccutil for own bundle across
  Accessibility/ScreenCapture/AppleEvents — works without sudo), footer shows
  bundle path + signature (ad-hoc highlighted orange).

**Permissions used:** Accessibility (tracking, titles, AXDocument, selection,
Cmd+V), Automation per browser (tab capture), Screen Recording (screenshots
only), Notifications (optional).

**Status checks:** `AXIsProcessTrusted`, `CGPreflightScreenCaptureAccess`,
`AEDeterminePermissionToAutomateTarget` (−1743 denied / −1744 not asked /
−600 not running), UN settings.

**Gotchas:**
- Automation prompt only fires while target browser is running.
- Grants belong to `/Applications` copy — running from `build/` or moving the
  binary invalidates them.
- Keychain can re-lock (new day) → codesign blocks on a dialog; build "hang"
  = click Always Allow.

**Links:** [[build-release]]

## Changelog
- 2026-07-06 — Initial note; state as of a744b63.
- 2026-07-02 — Stable identity + in-app reset + diagnostics footer (fbc33d0).
