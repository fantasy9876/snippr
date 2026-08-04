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

# Prefer the local "Snippr Dev" certificate (stable identity → TCC permissions
# survive rebuilds); fall back to ad-hoc signing when it isn't available.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Snippr Dev"; then
  codesign --force -s "Snippr Dev" "$APP"
  echo "signed with Snippr Dev certificate"
else
  codesign --force -s - "$APP"
fi
echo "✅ Built $APP ($(lipo -archs "$APP/Contents/MacOS/Snippr"))"
