#!/bin/sh
# Snippr installer for macOS. The canonical signer check is what lets an
# existing Screen Recording grant survive an update; a bundle signed by any
# other certificate is rejected before /Applications is touched.
set -eu

BASE_URL="https://snippr.pages.dev"
APP="/Applications/Snippr.app"
SIGNER_SHA1="946c43e6456970f5ec11544b3244c192aae949d6"
REQUIREMENT="identifier \"com.manhhoang.snippr\" and certificate root = H\"$SIGNER_SHA1\""

TMP="$(mktemp -d)"
MOUNT=""
STAGED="/Applications/.Snippr-install-$$.staged"
BACKUP="/Applications/.Snippr-install-$$.rollback"
BACKED_UP=0
ACTIVATED=0
TRANSACTION_STARTED=0

rollback() {
  if [ "$BACKED_UP" = "1" ] && [ -e "$BACKUP" ]; then
    if [ -e "$APP" ]; then
      rm -rf "$APP" || return 1
    fi
    [ ! -e "$APP" ] || return 1
    mv "$BACKUP" "$APP" || return 1
    BACKED_UP=0
    ACTIVATED=0
    TRANSACTION_STARTED=0
  elif [ "$TRANSACTION_STARTED" = "1" ] && [ -e "$APP" ]; then
    # Fresh install: there is no old bundle to restore, but a candidate that
    # failed verification/launch must not be left at the canonical path.
    rm -rf "$APP" || return 1
    [ ! -e "$APP" ] || return 1
    ACTIVATED=0
    TRANSACTION_STARTED=0
  fi
}

finish() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$status" -ne 0 ]; then
    rollback || echo "✗ Không thể rollback tự động; bản cũ còn tại $BACKUP" >&2
  fi
  [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
  rm -rf "$STAGED"
  rm -rf "$TMP"
  exit "$status"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -d "$HOME/Applications/Snippr.app" ]; then
  echo "✗ Phát hiện bản Snippr trùng tại $HOME/Applications/Snippr.app" >&2
  echo "  Hãy backup/xóa bản cũ đó trước; chạy nhầm bundle sẽ làm macOS báo sai quyền Screen Recording." >&2
  exit 1
fi

MANIFEST="$TMP/version.json"
curl -fsSL "$BASE_URL/version.json" -o "$MANIFEST"
VER="$(sed -n 's/.*"mac": *"\([0-9.]*\)".*/\1/p' "$MANIFEST")"
[ -n "$VER" ] || { echo "✗ Manifest thiếu version macOS" >&2; exit 1; }

ARCH="$(uname -m)"
if [ "$ARCH" = "arm64" ]; then
  DMG="Snippr-$VER.dmg"
  EXPECTED_SHA="$(sed -n 's/.*"macSha256Arm": *"\([0-9A-Fa-f]*\)".*/\1/p' "$MANIFEST")"
elif [ "$ARCH" = "x86_64" ]; then
  DMG="Snippr-$VER-intel.dmg"
  EXPECTED_SHA="$(sed -n 's/.*"macSha256Intel": *"\([0-9A-Fa-f]*\)".*/\1/p' "$MANIFEST")"
else
  echo "✗ Kiến trúc không được hỗ trợ: $ARCH" >&2
  exit 1
fi

case "$EXPECTED_SHA" in
  *[!0-9A-Fa-f]*|'') echo "✗ Manifest thiếu SHA-256 hợp lệ" >&2; exit 1 ;;
esac
[ ${#EXPECTED_SHA} -eq 64 ] || { echo "✗ SHA-256 phải có 64 ký tự" >&2; exit 1; }

echo "→ Tải $DMG ..."
curl -fsSL "$BASE_URL/$DMG" -o "$TMP/$DMG"
ACTUAL_SHA="$(shasum -a 256 "$TMP/$DMG" | awk '{print $1}')"
[ "$(printf '%s' "$ACTUAL_SHA" | tr '[:upper:]' '[:lower:]')" = \
  "$(printf '%s' "$EXPECTED_SHA" | tr '[:upper:]' '[:lower:]')" ] \
  || { echo "✗ SHA-256 không khớp; đã hủy" >&2; exit 1; }

MOUNT="$(hdiutil attach -nobrowse -readonly "$TMP/$DMG" \
  | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
[ -n "$MOUNT" ] && [ -d "$MOUNT/Snippr.app" ] \
  || { echo "✗ DMG không chứa Snippr.app" >&2; exit 1; }
[ ! -e "$STAGED" ] && [ ! -e "$BACKUP" ] \
  || { echo "✗ Đường dẫn staging đã tồn tại" >&2; exit 1; }

/usr/bin/ditto "$MOUNT/Snippr.app" "$STAGED"
/usr/bin/codesign --verify --deep --strict "-R=$REQUIREMENT" "$STAGED"
CANDIDATE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$STAGED/Contents/Info.plist")"
[ "$CANDIDATE_VERSION" = "$VER" ] \
  || { echo "✗ Version trong app ($CANDIDATE_VERSION) khác manifest ($VER)" >&2; exit 1; }

hdiutil detach "$MOUNT" -quiet
MOUNT=""

echo "→ Cài bản đã xác minh vào /Applications ..."
osascript -e 'tell application id "com.manhhoang.snippr" to quit' >/dev/null 2>&1 || true
remaining=15
while /usr/bin/pgrep -f "^$APP/Contents/MacOS/Snippr( |$)" >/dev/null 2>&1; do
  [ "$remaining" -gt 0 ] || { echo "✗ Snippr chưa thoát; không thay app" >&2; exit 1; }
  sleep 1
  remaining=$((remaining - 1))
done

if [ -e "$APP" ]; then
  BACKED_UP=1
  mv "$APP" "$BACKUP"
fi
TRANSACTION_STARTED=1
mv "$STAGED" "$APP"
ACTIVATED=1
/usr/bin/codesign --verify --deep --strict "-R=$REQUIREMENT" "$APP"

if ! open -n "$APP"; then
  echo "✗ Không mở được bản mới; đang rollback" >&2
  exit 1
fi
sleep 2
if ! /usr/bin/pgrep -f "^$APP/Contents/MacOS/Snippr( |$)" >/dev/null 2>&1; then
  echo "✗ Bản mới không duy trì tiến trình; đang rollback" >&2
  exit 1
fi

# The new app is now healthy: commit the transaction before best-effort
# cleanup. A cleanup warning must never delete the healthy app and restore a
# backup that may already be partially removed.
BACKED_UP=0
ACTIVATED=0
TRANSACTION_STARTED=0
if [ -e "$BACKUP" ] && ! rm -rf "$BACKUP"; then
  echo "⚠ Không xóa hết rollback cũ tại $BACKUP; app mới vẫn được giữ" >&2
fi
echo "✓ Đã cài Snippr $VER ($( [ "$ARCH" = "arm64" ] && echo 'Apple Silicon' || echo 'Intel' ))."
echo "  Cập nhật cùng danh tính ký sẽ giữ quyền; lần cài đầu vẫn cần cấp Screen Recording một lần."
