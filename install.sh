#!/usr/bin/env bash
# Run this on the Mac, from the repo root.
set -euo pipefail

cd "$(dirname "$0")"

if ! [ -d "/Applications/Hammerspoon.app" ] && ! [ -d "$HOME/Applications/Hammerspoon.app" ]; then
  echo "Hammerspoon not found. Install it first:"
  echo "  brew install --cask hammerspoon"
  exit 1
fi

SPOON_DIR="$HOME/.hammerspoon/Spoons"
mkdir -p "$SPOON_DIR"
rm -rf "$SPOON_DIR/ContextStack.spoon"
cp -R ContextStack.spoon "$SPOON_DIR/"
echo "Installed ContextStack.spoon to $SPOON_DIR"

INIT="$HOME/.hammerspoon/init.lua"
if [ -f "$INIT" ] && grep -q "ContextStack" "$INIT"; then
  echo "~/.hammerspoon/init.lua already references ContextStack — not touching it."
else
  cat examples/init-snippet.lua >> "$INIT"
  echo "Appended ContextStack config to $INIT"
fi

echo
echo "Now: launch Hammerspoon (or 'Reload Config' from its menu-bar icon),"
echo "grant Accessibility when prompted, and press Ctrl+Alt+Space."
