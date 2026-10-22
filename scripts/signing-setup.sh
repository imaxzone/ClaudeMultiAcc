#!/bin/bash
# One-time setup of the PERMANENT local signing identity "ClaudeMultiAcc Local Signing" (Doppel-style).
# A stable identity keeps each clone's designated requirement — and with it Keychain and TCC grants —
# stable across rebuilds. Interactive: macOS asks for the login keychain password during the import.
#
#   scripts/signing-setup.sh                create the identity, import it, record it
#   scripts/signing-setup.sh --dry-run      print every command without executing anything
#   scripts/signing-setup.sh --record-only  only (re)write identity.json and settings.json from the existing
#                                           <data>/signing/cert.pem; touches neither the keychain nor any key
#
# Files: <data>/signing/cert.pem and <data>/signing/identity.json (0600; key.pem and identity.p12 exist only until
# the import succeeds); settings.json gets builder.signingIdentitySHA1. The certificate is NOT marked as trusted.
# The private key is imported non-extractable (-x) and usable by /usr/bin/codesign only (-T). The one-time p12
# password never appears in argv: openssl reads it from the environment, `security` from its stdin (-i).
# The first codesign run may show a keychain prompt for the key: answer "Always Allow".
set -euo pipefail
umask 077

DRY_RUN=0
RECORD_ONLY=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  --record-only) RECORD_ONLY=1 ;;
  "") ;;
  *) echo "Usage: $0 [--dry-run|--record-only]" >&2; exit 64 ;;
esac

CN="ClaudeMultiAcc Local Signing"
DATA="${CMACC_DATA_DIR:-$HOME/Library/Application Support/ClaudeMultiAcc}"
SIGNING="$DATA/signing"
SETTINGS="$DATA/settings.json"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"
LEGACY=()
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then LEGACY=(-legacy); fi

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '%q ' "$@"; printf '\n'
  else
    "$@"
  fi
}

# Writes builder.signingIdentitySHA1 into settings.json. A missing, empty or `{}` file is written directly:
# plutil reads a bare `{}` as an old-style (OpenStep) plist and then refuses to save it.
write_settings_sha() {
  local sha="$1" compact=""
  [[ -s "$SETTINGS" ]] && compact="$(tr -d '[:space:]' < "$SETTINGS")"
  if [[ -z "$compact" || "$compact" == "{}" ]]; then
    printf '{"builder":{"signingIdentitySHA1":"%s"}}\n' "$sha" > "$SETTINGS"
  else
    plutil -extract builder raw "$SETTINGS" >/dev/null 2>&1 || plutil -insert builder -json '{}' "$SETTINGS"
    plutil -replace builder.signingIdentitySHA1 -string "$sha" "$SETTINGS"
  fi
  chmod 600 "$SETTINGS"
}

# Records the identity of <data>/signing/cert.pem in identity.json and settings.json.
record_identity() {
  [[ -s "$SIGNING/cert.pem" ]] || { echo "no certificate at $SIGNING/cert.pem; run $0 without flags first" >&2; exit 1; }
  local sha created
  sha="$(openssl x509 -in "$SIGNING/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
  created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"sha1":"%s","commonName":"%s","createdAt":"%s"}\n' "$sha" "$CN" "$created" > "$SIGNING/identity.json"
  chmod 600 "$SIGNING/identity.json"
  write_settings_sha "$sha"
  echo "Identity \"$CN\" ready: $sha"
}

if [[ $RECORD_ONLY -eq 1 ]]; then
  record_identity
  exit 0
fi

if [[ $DRY_RUN -eq 0 ]]; then
  if security find-certificate -c "$CN" "$LOGIN_KC" >/dev/null 2>&1; then
    if [[ -s "$SIGNING/cert.pem" ]]; then
      echo "A certificate named \"$CN\" already exists in the login keychain; recording it." >&2
      record_identity
      exit 0
    fi
    echo "A certificate named \"$CN\" already exists in the login keychain but $SIGNING/cert.pem is missing;" >&2
    echo "delete the certificate in Keychain Access and run this script again." >&2
    exit 1
  fi
  read -r -p "Create and import \"$CN\" into the login keychain? [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || { echo "aborted"; exit 1; }
fi

if [[ $DRY_RUN -eq 1 ]]; then CMACC_P12_PASS="<random>"; else CMACC_P12_PASS="$(openssl rand -hex 16)"; fi
export CMACC_P12_PASS
run mkdir -p "$SIGNING"
run chmod 700 "$SIGNING"
run openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$CN" \
  -addext keyUsage=critical,digitalSignature -addext extendedKeyUsage=codeSigning \
  -keyout "$SIGNING/key.pem" -out "$SIGNING/cert.pem"
run openssl pkcs12 -export "${LEGACY[@]}" -inkey "$SIGNING/key.pem" -in "$SIGNING/cert.pem" \
  -out "$SIGNING/identity.p12" -passout env:CMACC_P12_PASS
run chmod 600 "$SIGNING/key.pem" "$SIGNING/cert.pem" "$SIGNING/identity.p12"

# `security -i` reads the command (and with it the password) from stdin, so it never shows up in `ps`.
IMPORT="import \"$SIGNING/identity.p12\" -k \"$LOGIN_KC\" -f pkcs12 -x -T /usr/bin/codesign -P"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "security -i <<< '$IMPORT <password from CMACC_P12_PASS>'"
  echo "security find-certificate -c \"$CN\" \"$LOGIN_KC\"  # the import must have succeeded"
  echo "rm -f \"$SIGNING/key.pem\" \"$SIGNING/identity.p12\"  # keep cert.pem"
else
  printf '%s %s\n' "$IMPORT" "$CMACC_P12_PASS" | security -i
  if ! security find-certificate -c "$CN" "$LOGIN_KC" >/dev/null 2>&1; then
    echo "the import did not succeed; $SIGNING/identity.p12 is kept for a retry" >&2
    exit 1
  fi
  rm -f "$SIGNING/key.pem" "$SIGNING/identity.p12"
fi
unset CMACC_P12_PASS

if [[ $DRY_RUN -eq 1 ]]; then
  echo "write $SIGNING/identity.json: {\"sha1\":\"<sha1-of-cert.pem>\",\"commonName\":\"$CN\",\"createdAt\":\"<now>\"}"
  echo "set builder.signingIdentitySHA1=<sha1-of-cert.pem> in $SETTINGS"
  exit 0
fi

record_identity
