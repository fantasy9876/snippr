#!/bin/sh
# Snippr installer for macOS. The canonical signer check is what lets an
# existing Screen Recording grant survive an update; a bundle signed by any
# other certificate is rejected before /Applications is touched.
set -eu

INSTALL_LIBRARY_ONLY="${SNIPPR_INSTALL_LIBRARY_ONLY:-0}"
BASE_URL="https://snippr.pages.dev"
if [ "$INSTALL_LIBRARY_ONLY" = "1" ]; then
  APP="${SNIPPR_INSTALL_TEST_APP:?missing SNIPPR_INSTALL_TEST_APP}"
else
  APP="/Applications/Snippr.app"
fi
SIGNER_SHA1="946c43e6456970f5ec11544b3244c192aae949d6"
REQUIREMENT="identifier \"com.manhhoang.snippr\" and certificate root = H\"$SIGNER_SHA1\""
# Canonical startup can spend 15 s evicting a stale wrong-signature copy.
# Keep the rollback journal beyond that bound and normal initialization.
if [ "$INSTALL_LIBRARY_ONLY" = "1" ]; then
  HEALTH_FILE="${SNIPPR_INSTALL_TEST_HEALTH_FILE:?missing test health file}"
  HEALTH_TIMEOUT="${SNIPPR_INSTALL_TEST_HEALTH_TIMEOUT:-25}"
  CANDIDATE_STOP_GRACE="${SNIPPR_INSTALL_TEST_STOP_GRACE:-12}"
  CANDIDATE_STOP_FORCE="${SNIPPR_INSTALL_TEST_STOP_FORCE:-3}"
else
  HEALTH_FILE="$HOME/Library/Application Support/Snippr/status.txt"
  HEALTH_TIMEOUT=25
  CANDIDATE_STOP_GRACE=12
  CANDIDATE_STOP_FORCE=3
fi
[ "$HEALTH_TIMEOUT" -ge $((CANDIDATE_STOP_GRACE + CANDIDATE_STOP_FORCE + 5)) ] \
  || { echo "✗ Cấu hình health/rollback không an toàn" >&2; exit 1; }

if [ "$INSTALL_LIBRARY_ONLY" = "1" ]; then
  TMP="${SNIPPR_INSTALL_TEST_TMP:?missing SNIPPR_INSTALL_TEST_TMP}"
  mkdir -p "$TMP"
else
  TMP="$(mktemp -d)"
fi
MOUNT=""
APP_PARENT="${APP%/*}"
STAGED="$APP_PARENT/.Snippr-install-$$.staged"
BACKUP="$APP_PARENT/.Snippr-install-$$.rollback"
BACKED_UP=0
ACTIVATED=0
TRANSACTION_STARTED=0
EXPECTED_EXECUTABLE="$APP/Contents/MacOS/Snippr"
physical_path() {
  /bin/realpath -q "$1" 2>/dev/null || return 1
}
expected_physical() {
  [ "$ACTIVATED" = "1" ] || return 1
  physical_path "$EXPECTED_EXECUTABLE"
}
if [ "$INSTALL_LIBRARY_ONLY" = "1" ]; then
  GRACEFUL_TERMINATE_TOOL="${SNIPPR_INSTALL_TEST_GRACEFUL_TOOL:?missing graceful tool}"
  CANDIDATE_SIGNAL_TOOL="${SNIPPR_INSTALL_TEST_SIGNAL_TOOL:?missing signal tool}"
else
  GRACEFUL_TERMINATE_TOOL="$EXPECTED_EXECUTABLE"
  CANDIDATE_SIGNAL_TOOL="/bin/kill"
fi

candidate_pid_matches() {
  CANDIDATE_PID="$1"
  case "$CANDIDATE_PID" in *[!0-9]*|'') return 1 ;; esac
  /bin/kill -0 "$CANDIDATE_PID" 2>/dev/null || return 1
  EXPECTED_PHYSICAL=$(expected_physical) || return 1
  [ -n "$EXPECTED_PHYSICAL" ] || return 1
  /usr/sbin/lsof -a -p "$CANDIDATE_PID" -d txt -Fn 2>/dev/null \
    | /usr/bin/sed -n 's/^n//p' \
    | while IFS= read -r LSOF_PATH; do
        [ -n "$LSOF_PATH" ] || continue
        LSOF_PHYSICAL=$(physical_path "$LSOF_PATH") || continue
        [ "$LSOF_PHYSICAL" = "$EXPECTED_PHYSICAL" ] && /usr/bin/printf '%s\n' HIT
      done \
    | /usr/bin/grep -qx HIT
}

candidate_pids() {
  /usr/bin/pgrep -f 'Snippr' 2>/dev/null | while IFS= read -r CANDIDATE_PID; do
    if candidate_pid_matches "$CANDIDATE_PID"; then
      /usr/bin/printf '%s\n' "$CANDIDATE_PID"
    fi
  done
}

candidate_alive() {
  [ -n "$(candidate_pids)" ]
}

stop_activated_candidate() {
  [ "$ACTIVATED" = "1" ] || return 0
  CANDIDATE_PIDS="$(candidate_pids)"
  [ -n "$CANDIDATE_PIDS" ] || return 0
  echo "→ Dừng candidate trước khi rollback ..." >&2
  HELPER_PIDS=""
  for CANDIDATE_PID in $CANDIDATE_PIDS; do
    if candidate_pid_matches "$CANDIDATE_PID"; then
      "$GRACEFUL_TERMINATE_TOOL" --request-terminate-pid "$CANDIDATE_PID" \
        >/dev/null 2>&1 &
      HELPER_PIDS="$HELPER_PIDS $!"
    fi
  done
  STOP_REMAINING=$CANDIDATE_STOP_GRACE
  while candidate_alive && [ "$STOP_REMAINING" -gt 0 ]; do
    /bin/sleep 1
    STOP_REMAINING=$((STOP_REMAINING - 1))
  done
  CANDIDATE_PIDS="$(candidate_pids)"
  if [ -n "$CANDIDATE_PIDS" ]; then
    for CANDIDATE_PID in $CANDIDATE_PIDS; do
      if candidate_pid_matches "$CANDIDATE_PID"; then
        "$CANDIDATE_SIGNAL_TOOL" -KILL "$CANDIDATE_PID" 2>/dev/null || true
      fi
    done
  fi
  STOP_REMAINING=$CANDIDATE_STOP_FORCE
  while candidate_alive && [ "$STOP_REMAINING" -gt 0 ]; do
    /bin/sleep 1
    STOP_REMAINING=$((STOP_REMAINING - 1))
  done
  for HELPER_PID in $HELPER_PIDS; do
    if /bin/kill -0 "$HELPER_PID" 2>/dev/null; then
      /bin/kill -KILL "$HELPER_PID" 2>/dev/null || true
    fi
    wait "$HELPER_PID" 2>/dev/null || true
  done
  ! candidate_alive
}

rollback() {
  if ! stop_activated_candidate; then
    echo "✗ Candidate vẫn đang chạy; giữ nguyên app mới và rollback journal tại $BACKUP" >&2
    return 1
  fi
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

wait_for_health() {
  remaining=$HEALTH_TIMEOUT
  while [ "$remaining" -gt 0 ]; do
    if [ -f "$HEALTH_FILE" ]; then
      HEALTH_PID="$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' "$HEALTH_FILE" | head -1)"
      HEALTH_VERSION="$(sed -n 's/^version=\(.*\)$/\1/p' "$HEALTH_FILE" | head -1)"
      HEALTH_BUILD="$(sed -n 's/^build=\(.*\)$/\1/p' "$HEALTH_FILE" | head -1)"
      HEALTH_EXECUTABLE="$(sed -n 's/^executable=\(.*\)$/\1/p' "$HEALTH_FILE" | head -1)"
      HEALTH_PHYSICAL=$(physical_path "$HEALTH_EXECUTABLE") || HEALTH_PHYSICAL=""
      EXPECTED_PHYSICAL=$(expected_physical) || EXPECTED_PHYSICAL=""
      if [ -n "$HEALTH_PID" ] \
        && [ "$HEALTH_VERSION" = "$CANDIDATE_VERSION" ] \
        && [ "$HEALTH_BUILD" = "$CANDIDATE_BUILD" ] \
        && [ -n "$HEALTH_PHYSICAL" ] && [ -n "$EXPECTED_PHYSICAL" ] \
        && [ "$HEALTH_PHYSICAL" = "$EXPECTED_PHYSICAL" ] \
        && candidate_pid_matches "$HEALTH_PID"; then
        /bin/sleep 1
        if candidate_pid_matches "$HEALTH_PID"; then
          return 0
        fi
      fi
    fi
    /bin/sleep 1
    remaining=$((remaining - 1))
  done
  return 1
}

commit_transaction() {
  BACKED_UP=0
  ACTIVATED=0
  TRANSACTION_STARTED=0
  if [ -e "$BACKUP" ] && ! rm -rf "$BACKUP"; then
    echo "⚠ Không xóa hết rollback cũ tại $BACKUP; app mới vẫn được giữ" >&2
  fi
}

finish() {
  status=$?
  trap - EXIT
  trap '' HUP INT TERM
  if [ "$status" -ne 0 ]; then
    rollback || echo "✗ Không thể rollback tự động; bản cũ còn tại $BACKUP" >&2
  fi
  [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
  rm -rf "$STAGED"
  rm -rf "$TMP"
  exit "$status"
}

install_transaction_traps() {
  trap finish EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# Release validation sources these exact production functions into an
# isolated temp transaction. Normal curl|sh execution never sets this mode.
if [ "$INSTALL_LIBRARY_ONLY" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

install_transaction_traps

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
CANDIDATE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
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

rm -f "$HEALTH_FILE"
if ! /usr/bin/open -n "$APP"; then
  echo "✗ Không mở được bản mới; đang rollback" >&2
  exit 1
fi

echo "→ Chờ bản mới khởi động an toàn ..."
wait_for_health || {
  echo "✗ Bản mới không ghi health hợp lệ trong ${HEALTH_TIMEOUT}s; đang rollback" >&2
  exit 1
}

# The new app is now healthy: commit the transaction before best-effort
# cleanup. A cleanup warning must never delete the healthy app and restore a
# backup that may already be partially removed.
commit_transaction
echo "✓ Đã cài Snippr $VER ($( [ "$ARCH" = "arm64" ] && echo 'Apple Silicon' || echo 'Intel' ))."
echo "  Cập nhật cùng danh tính ký sẽ giữ quyền; lần cài đầu vẫn cần cấp Screen Recording một lần."
