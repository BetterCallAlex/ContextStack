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
if [ -z "$IDENTITY" ]; then
    echo "note: no CODESIGN_IDENTITY set — using ad-hoc signing."
    echo "      Permission grants may need re-granting after each rebuild."
    IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP"

echo
echo "Built: $PWD/$APP"
echo "Install: cp -R $APP /Applications/   then: open /Applications/ContextStack.app"
