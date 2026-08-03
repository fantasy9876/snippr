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

# Ad-hoc sign so TCC permissions (Screen Recording, Accessibility) stick between builds
codesign --force -s - "$APP"
echo "✅ Built $APP ($(lipo -archs "$APP/Contents/MacOS/Snippr"))"
