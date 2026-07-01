#!/usr/bin/env bash
# One-time setup: create a self-signed code-signing certificate in the login
# keychain so ContextStack.app keeps the same signing identity across
# rebuilds. macOS ties permission grants (Accessibility, Screen Recording,
# Automation) to the code signature; with the default ad-hoc signing the
# signature changes on every build and the grants go stale.
#
# Expect two interactive dialogs:
#   1. a password prompt when the certificate is added to Trust Settings
#   2. on the first codesign run, "codesign wants to access key ..."
#      → click "Always Allow"
set -euo pipefail

NAME="${1:-ContextStack Local Signing}"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "identity '$NAME' already present and valid"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -subj "/CN=$NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null

security import "$TMP/key.pem" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -T /usr/bin/codesign
security import "$TMP/cert.pem" \
    -k "$HOME/Library/Keychains/login.keychain-db"

# Trust for code signing (user trust domain) — triggers the password dialog.
if ! security add-trusted-cert -r trustRoot -p codeSign \
    -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem"; then
    echo "Trust step failed or was cancelled."
    echo "Manual fallback: open Keychain Access → login → Certificates,"
    echo "double-click '$NAME' → Trust → Code Signing: Always Trust."
    exit 1
fi

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "created identity: $NAME"
else
    echo "identity created but not yet listed as valid — check Keychain Access trust settings"
    exit 1
fi
