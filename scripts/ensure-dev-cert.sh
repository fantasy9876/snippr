#!/bin/zsh
# Ensure a STABLE local code-signing identity named "Snippr Dev" exists.
#
# Why: macOS TCC (Screen Recording / Accessibility) binds a grant to the app's
# designated requirement. An ad-hoc signature has DR = cdhash of that exact
# binary, so EVERY rebuild/update invalidates the grant and capture silently
# stops working ("toggle is on but nothing is captured"). A self-signed cert
# gives DR = identifier + certificate root, which survives rebuilds.
#
# The identity lives in its own keychain (~/Library/Keychains/snippr-dev.keychain-db)
# with its password stored 0600 next to it, so `codesign` never prompts —
# including after a reboot (build.sh unlocks it before signing).
#
# To share ONE identity across machines (so grants match everywhere), copy the
# keychain, its password file, and the adjacent .cert.pem file to the other Mac.
# This script adds that existing keychain to the search list and trusts its
# certificate; it never creates a replacement in required-release mode.
set -euo pipefail

NAME="Snippr Dev"
KC="$HOME/Library/Keychains/snippr-dev.keychain-db"
PW_FILE="$HOME/Library/Keychains/snippr-dev.password"
REQUIRED_SHA1="${SNIPPR_REQUIRED_SIGNER_SHA1:-}"

normalize_sha1() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -d ':'
}

have_required_identity() {
  local wanted
  wanted="$(normalize_sha1 "$REQUIRED_SHA1")"
  [ ${#wanted} -eq 40 ] || return 1
  security find-identity -v -p codesigning 2>/dev/null \
    | awk '{print toupper($2)}' | grep -qx "$wanted"
}

prepare_existing_keychain() {
  [ -f "$PW_FILE" ] && [ -f "$KC" ] || return 1
  local password current
  password="$(cat "$PW_FILE")"
  security unlock-keychain -p "$password" "$KC" 2>/dev/null || return 1
  current="$(security list-keychains -d user | tr -d '\" ' )"
  if ! printf '%s\n' "$current" | grep -qx "$KC"; then
    security list-keychains -d user -s $(printf '%s\n' "$current") "$KC"
  fi
}

# Distribution builds set the canonical public fingerprint. In this mode a
# missing key is a hard failure: creating another self-signed certificate would
# produce a different designated requirement and invalidate existing TCC grants.
if [ -n "$REQUIRED_SHA1" ]; then
  prepare_existing_keychain || true
  if have_required_identity; then
    echo "ensure-dev-cert: required release identity $(normalize_sha1 "$REQUIRED_SHA1") ready"
    exit 0
  fi
  # A transferred keychain may be on the search list but not yet trusted for
  # code signing. Only import trust when the companion public certificate is
  # itself the exact required identity; never touch trust for a wrong request.
  if [ -f "$KC.cert.pem" ]; then
    CERT_SHA1="$(openssl x509 -in "$KC.cert.pem" -noout -fingerprint -sha1 \
      | sed 's/^.*=//' | tr -d ':')"
    if [ "$(normalize_sha1 "$CERT_SHA1")" = "$(normalize_sha1 "$REQUIRED_SHA1")" ]; then
      security add-trusted-cert -r trustRoot -p codeSign -k "$KC" \
        "$KC.cert.pem" >/dev/null 2>&1 || true
    fi
  fi
  if have_required_identity; then
    echo "ensure-dev-cert: required release identity $(normalize_sha1 "$REQUIRED_SHA1") ready"
    exit 0
  fi
  echo "ensure-dev-cert: FAILED — required release identity $(normalize_sha1 "$REQUIRED_SHA1") is unavailable" >&2
  echo "ensure-dev-cert: refusing to create a replacement certificate because it would lose TCC grants" >&2
  exit 1
fi

have_valid_identity() {
  security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$NAME\""
}

if have_valid_identity; then
  [ -f "$PW_FILE" ] && security unlock-keychain -p "$(cat "$PW_FILE")" "$KC" 2>/dev/null || true
  echo "ensure-dev-cert: '$NAME' identity present"
  exit 0
fi

if [ ! -f "$KC" ] || [ ! -f "$PW_FILE" ]; then
  echo "ensure-dev-cert: creating self-signed '$NAME' identity in $KC"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  PW="$(openssl rand -hex 24)"
  umask 077
  printf '%s' "$PW" > "$PW_FILE"
  cat > "$TMP/ext.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=$NAME
O=Snippr
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
CNF
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/ext.cnf" >/dev/null 2>&1
  openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout "pass:$PW" -name "$NAME"
  security delete-keychain "$KC" >/dev/null 2>&1 || true
  security create-keychain -p "$PW" "$KC"
  security set-keychain-settings "$KC"            # never auto-lock
  security unlock-keychain -p "$PW" "$KC"
  security import "$TMP/id.p12" -k "$KC" -P "$PW" -A \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
  cp "$TMP/cert.pem" "$KC.cert.pem"
fi

PW="$(cat "$PW_FILE")"
security unlock-keychain -p "$PW" "$KC"
# Add to the user search list (idempotent) so codesign can see it.
CURRENT=$(security list-keychains -d user | tr -d '" ' )
if ! printf '%s\n' "$CURRENT" | grep -qx "$KC"; then
  security list-keychains -d user -s $(printf '%s\n' "$CURRENT") "$KC"
fi
# Trust the self-signed cert for code signing (user domain, no admin needed).
if [ -f "$KC.cert.pem" ]; then
  security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$KC.cert.pem" >/dev/null 2>&1 || true
fi

if have_valid_identity; then
  echo "ensure-dev-cert: '$NAME' identity ready"
else
  echo "ensure-dev-cert: FAILED — no valid '$NAME' identity" >&2
  exit 1
fi
