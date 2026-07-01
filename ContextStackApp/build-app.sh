#!/usr/bin/env bash
# Build ContextStack.app from the SwiftPM package.
#
# TCC (Accessibility / Screen Recording / Automation) ties grants to the code
# signature. With ad-hoc signing (the default when no identity is available)
# the signature changes on every rebuild, so macOS may ask again. Set
# CODESIGN_IDENTITY to a real identity to keep grants across rebuilds.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

# Assemble and sign in a staging dir OUTSIDE the repo: if the repo lives in
# an iCloud-synced folder (Desktop/Documents), the file provider keeps
# stamping com.apple.FinderInfo xattrs on the bundle, which codesign rejects
# as "detritus". /tmp is never synced.
STAGE="$(mktemp -d /tmp/contextstack-build.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
APP_STAGE="$STAGE/ContextStack.app"
mkdir -p "$APP_STAGE/Contents/MacOS" "$APP_STAGE/Contents/Resources"
cp .build/release/ContextStack "$APP_STAGE/Contents/MacOS/ContextStack"
cp Resources/Info.plist "$APP_STAGE/Contents/Info.plist"

# App icon is drawn in code (IconKit.swift) — render + pack it here.
.build/release/ContextStack --render-icon "$STAGE/AppIcon.iconset"
rm -f "$STAGE/AppIcon.iconset/preview.png" "$STAGE/AppIcon.iconset/preview-menubar.png"
iconutil -c icns -o "$APP_STAGE/Contents/Resources/AppIcon.icns" "$STAGE/AppIcon.iconset"

IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null \
        | grep -q "ContextStack Local Signing"; then
    IDENTITY="ContextStack Local Signing"
fi
if [ -z "$IDENTITY" ]; then
    echo "note: no signing identity — using ad-hoc signing. Permission grants"
    echo "      go stale on every rebuild. Run ./make-signing-cert.sh once to fix."
    IDENTITY="-"
fi
echo "signing with: $IDENTITY"
xattr -cr "$APP_STAGE" 2>/dev/null || true
codesign --force --sign "$IDENTITY" "$APP_STAGE"
codesign --verify --strict "$APP_STAGE"
echo "signature verified"

APP="build/ContextStack.app"
rm -rf "$APP"
mkdir -p build
ditto "$APP_STAGE" "$APP"

if [ "${1:-}" = "install" ]; then
    # Plain cp would drag the sync-service xattrs along and fail strict
    # verification; --noextattr keeps the installed copy clean.
    rm -rf /Applications/ContextStack.app
    ditto --noextattr --noqtn "$APP_STAGE" /Applications/ContextStack.app
    codesign --verify --strict /Applications/ContextStack.app
    echo "installed + verified: /Applications/ContextStack.app"
else
    echo
    echo "Built: $PWD/$APP"
    echo "Install: ./build-app.sh install   (or: ditto --noextattr build/ContextStack.app /Applications/ContextStack.app)"
fi
