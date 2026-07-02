#!/usr/bin/env bash
# Build a distributable ContextStack-<version>.dmg (app + /Applications
# symlink). Note: without an Apple Developer ID + notarization, downloaded
# copies hit Gatekeeper on first launch — users approve once via
# System Settings → Privacy & Security → "Open Anyway".
set -euo pipefail
cd "$(dirname "$0")"

./build-app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
STAGE=$(mktemp -d /tmp/contextstack-dmg.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT

mkdir "$STAGE/ContextStack"
ditto --noextattr --noqtn build/ContextStack.app "$STAGE/ContextStack/ContextStack.app"
ln -s /Applications "$STAGE/ContextStack/Applications"

DMG="build/ContextStack-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "ContextStack" -srcfolder "$STAGE/ContextStack" \
    -ov -format UDZO "$DMG" >/dev/null

echo "Created $PWD/$DMG"
