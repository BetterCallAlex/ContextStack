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

APP="build/ContextStack.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ContextStack "$APP/Contents/MacOS/ContextStack"
cp Resources/Info.plist "$APP/Contents/Info.plist"

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
codesign --force --sign "$IDENTITY" "$APP"

echo
echo "Built: $PWD/$APP"
echo "Install: cp -R $APP /Applications/   then: open /Applications/ContextStack.app"
