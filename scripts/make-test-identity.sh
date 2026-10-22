#!/bin/bash
# Creates a throwaway code-signing identity in a NEW keychain file (tests and experiment E2 only).
# Never touches the login keychain and verifies that the user keychain search list is unchanged.
# Usage: scripts/make-test-identity.sh <keychain-path>   → prints the identity's SHA-1 on stdout.
# Cleanup: security delete-keychain <keychain-path>
set -euo pipefail
[[ $# -eq 1 ]] || { echo "Usage: $0 <keychain-path>" >&2; exit 64; }
KC="$1"; PASS="cmacc-test"; WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
[[ -e "$KC" ]] && { echo "refusing to overwrite existing $KC" >&2; exit 1; }

# PKCS#12 files from OpenSSL 3 need -legacy for `security import`; LibreSSL has no such flag.
LEGACY=()
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then LEGACY=(-legacy); fi

BEFORE="$(security list-keychains -d user)"
security create-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$PASS" "$KC"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=ClaudeMultiAcc Test Signing" \
  -addext keyUsage=critical,digitalSignature -addext extendedKeyUsage=codeSigning \
  -keyout "$WORK/k.pem" -out "$WORK/c.pem" 2>/dev/null
openssl pkcs12 -export "${LEGACY[@]}" -inkey "$WORK/k.pem" -in "$WORK/c.pem" -out "$WORK/i.p12" -passout pass:"$PASS"
security import "$WORK/i.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null
AFTER="$(security list-keychains -d user)"
[ "$BEFORE" = "$AFTER" ] || { security delete-keychain "$KC"; echo "search list changed — aborted" >&2; exit 1; }
openssl x509 -in "$WORK/c.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g'
