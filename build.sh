#!/bin/zsh
# Build Snippr.app (arm64 native, Apple Silicon)
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
ARCH="${2:-arm64}"
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "❌ unsupported architecture: $ARCH (expected arm64 or x86_64)" >&2; exit 1 ;;
esac

# Fail before compiling if any platform icon has drifted from the approved,
# transparent master. This also prevents the stale procedural S logo from
# returning in a future release.
swift Support/makeicon.swift --check
swift build -c "$CONFIG" --arch "$ARCH"

EXPECTED_SIGNER_SHA1="$(/usr/libexec/PlistBuddy -c 'Print :SnipprReleaseSignerSHA1' Support/Info.plist \
  | tr '[:upper:]' '[:lower:]' | tr -d ':')"
case "$EXPECTED_SIGNER_SHA1" in
  (*[!0-9a-f]*|'') echo "❌ invalid SnipprReleaseSignerSHA1 in Support/Info.plist" >&2; exit 1 ;;
esac
if [ ${#EXPECTED_SIGNER_SHA1} -ne 40 ]; then
  echo "❌ SnipprReleaseSignerSHA1 must contain exactly 40 hex characters" >&2
  exit 1
fi

APP="build/Snippr.app"
BIN=".build/$ARCH-apple-macosx/$CONFIG/Snippr"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Snippr"
cp Support/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f Support/AppIcon.icns ]; then
  cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Sign with the local "Snippr Dev" certificate: a STABLE identity, so the
# designated requirement is identifier+certificate and TCC grants (Screen
# Recording / Accessibility) survive rebuilds. Ad-hoc signing pins the grant to
# one cdhash — every new build silently loses capture permission. The
# certificate is created on demand; ad-hoc is only allowed for debug builds
# or when SNIPPR_ALLOW_ADHOC=1 is set explicitly.
if [ "$CONFIG" = "release" ] && [ "${SNIPPR_ALLOW_ADHOC:-0}" != "1" ]; then
  SNIPPR_REQUIRED_SIGNER_SHA1="$EXPECTED_SIGNER_SHA1" ./scripts/ensure-dev-cert.sh
  codesign --force -s "$EXPECTED_SIGNER_SHA1" "$APP"
  echo "signed with canonical Snippr release certificate $EXPECTED_SIGNER_SHA1"
elif ./scripts/ensure-dev-cert.sh; then
  codesign --force -s "Snippr Dev" "$APP"
  echo "signed with local Snippr Dev certificate"
elif [ "$CONFIG" != "release" ] || [ "${SNIPPR_ALLOW_ADHOC:-0}" = "1" ]; then
  echo "⚠️  Snippr Dev identity unavailable — signing AD-HOC (TCC grants will not survive rebuilds)" >&2
  codesign --force -s - "$APP"
else
  echo "❌ release build requires the 'Snippr Dev' identity (set SNIPPR_ALLOW_ADHOC=1 to override)" >&2
  exit 1
fi
DR_LINE="$(codesign -d -r- "$APP" 2>&1 | grep 'designated')"
DR="${DR_LINE#*=> }"
echo "$DR_LINE"
if [ "$CONFIG" = "release" ] && [ "${SNIPPR_ALLOW_ADHOC:-0}" != "1" ]; then
  EXPECTED_DR="identifier \"com.manhhoang.snippr\" and certificate root = H\"$EXPECTED_SIGNER_SHA1\""
  if [ "$DR" != "$EXPECTED_DR" ]; then
    echo "❌ release signer requirement mismatch" >&2
    echo "   expected: $EXPECTED_DR" >&2
    echo "   actual:   $DR" >&2
    exit 1
  fi
fi
BUILT_ARCH="$(lipo -archs "$APP/Contents/MacOS/Snippr")"
if [ "$BUILT_ARCH" != "$ARCH" ]; then
  echo "❌ bundled architecture mismatch: expected $ARCH, got $BUILT_ARCH" >&2
  exit 1
fi
echo "✅ Built $APP ($BUILT_ARCH)"
