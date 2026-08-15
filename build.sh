#!/bin/zsh
# Build Snippr.app (arm64 native, Apple Silicon)
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG" --arch arm64

APP="build/Snippr.app"
BIN=".build/arm64-apple-macosx/$CONFIG/Snippr"

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
if ./scripts/ensure-dev-cert.sh; then
  codesign --force -s "Snippr Dev" "$APP"
  echo "signed with Snippr Dev certificate"
elif [ "$CONFIG" != "release" ] || [ "${SNIPPR_ALLOW_ADHOC:-0}" = "1" ]; then
  echo "⚠️  Snippr Dev identity unavailable — signing AD-HOC (TCC grants will not survive rebuilds)" >&2
  codesign --force -s - "$APP"
else
  echo "❌ release build requires the 'Snippr Dev' identity (set SNIPPR_ALLOW_ADHOC=1 to override)" >&2
  exit 1
fi
DR="$(codesign -d -r- "$APP" 2>&1 | grep 'designated')"
echo "$DR"
if [ "$CONFIG" = "release" ] && [ "${SNIPPR_ALLOW_ADHOC:-0}" != "1" ] && echo "$DR" | grep -q cdhash; then
  echo "❌ designated requirement is cdhash-pinned; TCC grants would not survive rebuilds" >&2
  exit 1
fi
echo "✅ Built $APP ($(lipo -archs "$APP/Contents/MacOS/Snippr"))"
