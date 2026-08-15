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
# To share ONE identity across machines (so grants match everywhere), copy both
# files to the other Mac and run this script there once — it only adds the
# keychain to the search list and trusts the certificate.
set -euo pipefail

NAME="Snippr Dev"
KC="$HOME/Library/Keychains/snippr-dev.keychain-db"
PW_FILE="$HOME/Library/Keychains/snippr-dev.password"

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
