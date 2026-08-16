#!/bin/sh
# Snippr installer for macOS
# Downloads with curl (no browser quarantine flag) so Gatekeeper's
# "could not verify free of malware" dialog never appears.
set -e

# always install the latest published version (read from version.json,
# fall back to a known-good release if the fetch fails)
VER=$(curl -fsSL "https://snippr.pages.dev/version.json" 2>/dev/null \
  | sed -n 's/.*"mac": *"\([0-9.]*\)".*/\1/p')
[ -n "$VER" ] || VER="1.2.2"

ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
  DMG="Snippr-$VER.dmg"
else
  DMG="Snippr-$VER-intel.dmg"
fi

echo "→ Tải $DMG ..."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "https://snippr.pages.dev/$DMG" -o "$TMP/$DMG"

# Only /Applications/Snippr.app is canonical: macOS ties Screen Recording /
# Accessibility grants to the installed app's signature; a second copy with the
# same bundle id (an old drag-install in ~/Applications, a Downloads copy) can be
# opened by Spotlight/Launchpad instead and the user is asked to grant again.
# Never delete on the user's behalf — name them.
DUPES=$(mdfind "kMDItemCFBundleIdentifier == 'com.manhhoang.snippr'" 2>/dev/null   | grep -v '^/Applications/Snippr.app$' | grep -v '^/Volumes/' || true)
if [ -n "$DUPES" ]; then
  echo "⚠️  Có bản Snippr khác trên máy — hãy xóa để không bị hỏi lại quyền Screen Recording:"
  printf '   %s\n' $DUPES
fi

echo "→ Cài vào /Applications ..."
MOUNT=$(hdiutil attach -nobrowse -readonly "$TMP/$DMG" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)
osascript -e 'quit app "Snippr"' >/dev/null 2>&1 || true
sleep 1
rm -rf /Applications/Snippr.app
cp -R "$MOUNT/Snippr.app" /Applications/
hdiutil detach "$MOUNT" -quiet
xattr -cr /Applications/Snippr.app 2>/dev/null || true

echo "✓ Đã cài Snippr $( [ "$ARCH" = "arm64" ] && echo '(Apple Silicon)' || echo '(Intel)' ). Đang mở..."
open /Applications/Snippr.app
echo ""
echo "Lưu ý: lần đầu chạy hãy cấp quyền Screen Recording"
echo "(System Settings → Privacy & Security → Screen Recording → bật Snippr, rồi mở lại app)."
