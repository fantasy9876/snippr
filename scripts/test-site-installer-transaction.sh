#!/bin/sh
# Hermetic execution gate for the exact rollback/health functions published in
# site/install.sh. All app paths live under mktemp; /Applications and TCC are
# never touched.
set -eu

REPO_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
INSTALLER="$REPO_ROOT/site/install.sh"
# Use the physical /private/tmp prefix because lsof reports canonical paths;
# /var is a symlink to /private/var on macOS and would make an exact-path
# process check fail for the wrong reason.
ROOT="$(mktemp -d /private/tmp/snippr-site-installer.XXXXXX)"
FIXTURE_SOURCE="$ROOT/SnipprFixture.c"
FIXTURE_BINARY="$ROOT/SnipprFixture"

# A copied Apple platform binary such as /bin/sleep can be killed by macOS
# library-validation policy after relocation. Compile a tiny ordinary process
# instead so the transaction gate is testing rollback semantics, not platform
# binary provenance.
/usr/bin/printf '%s\n' \
  '#include <unistd.h>' \
  'int main(void) {' \
  '  for (;;) sleep(1);' \
  '}' > "$FIXTURE_SOURCE"
/usr/bin/clang "$FIXTURE_SOURCE" -o "$FIXTURE_BINARY"

cleanup() {
  for PID_FILE in "$ROOT"/*/*.pid; do
    [ -f "$PID_FILE" ] || continue
    PID="$(sed -n '1p' "$PID_FILE")"
    case "$PID" in *[!0-9]*|'') continue ;; esac
    /bin/kill -KILL "$PID" 2>/dev/null || true
  done
  rm -rf "$ROOT"
}
trap cleanup EXIT HUP INT TERM

make_app() {
  TARGET="$1"
  MARKER="$2"
  mkdir -p "$TARGET/Contents/MacOS" "$TARGET/Contents/Resources"
  cp "$FIXTURE_BINARY" "$TARGET/Contents/MacOS/Snippr"
  /usr/bin/printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict>' \
    '<key>CFBundleExecutable</key><string>Snippr</string>' \
    '<key>CFBundleIdentifier</key><string>com.example.snippr-transaction-fixture</string>' \
    '<key>CFBundlePackageType</key><string>APPL</string>' \
    '</dict></plist>' > "$TARGET/Contents/Info.plist"
  /usr/bin/printf '%s\n' "$MARKER" > "$TARGET/Contents/Resources/fixture-version"
  /usr/bin/codesign --force --sign - "$TARGET" >/dev/null 2>&1
}

marker() {
  sed -n '1p' "$1/Contents/Resources/fixture-version" 2>/dev/null || true
}

make_tools() {
  CASE_ROOT="$1"
  MODE="$2"
  GRACEFUL="$CASE_ROOT/graceful.sh"
  SIGNAL="$CASE_ROOT/signal.sh"
  if [ "$MODE" = "polite" ]; then
    /usr/bin/printf '%s\n' \
      '#!/bin/sh' \
      'printf "%s %s\n" "$1" "$2" >> "$SNIPPR_TEST_SIGNAL_LOG"' \
      'exec /bin/kill -TERM "$2"' > "$GRACEFUL"
  elif [ "$MODE" = "force" ]; then
    /usr/bin/printf '%s\n' \
      '#!/bin/sh' \
      'printf "%s %s\n" "$1" "$2" >> "$SNIPPR_TEST_SIGNAL_LOG"' \
      'printf "%s\n" "$$" > "$SNIPPR_TEST_HELPER_PID_FILE"' \
      'exec /bin/sleep 30' > "$GRACEFUL"
  else
    /usr/bin/printf '%s\n' \
      '#!/bin/sh' \
      'printf "%s %s\n" "$1" "$2" >> "$SNIPPR_TEST_SIGNAL_LOG"' \
      'exit 0' > "$GRACEFUL"
  fi
  if [ "$MODE" = "immortal" ]; then
    /usr/bin/printf '%s\n' \
      '#!/bin/sh' \
      'printf "%s %s\n" "$1" "$2" >> "$SNIPPR_TEST_SIGNAL_LOG"' \
      'exit 0' > "$SIGNAL"
  else
    /usr/bin/printf '%s\n' \
      '#!/bin/sh' \
      'printf "%s %s\n" "$1" "$2" >> "$SNIPPR_TEST_SIGNAL_LOG"' \
      'exec /bin/kill "$@"' > "$SIGNAL"
  fi
  chmod 755 "$GRACEFUL" "$SIGNAL"
}

run_failure_case() (
  MODE="$1"
  CASE_ROOT="$ROOT/$MODE"
  mkdir -p "$CASE_ROOT"
  make_tools "$CASE_ROOT" "$MODE"
  export SNIPPR_TEST_SIGNAL_LOG="$CASE_ROOT/signals.log"
  export SNIPPR_TEST_HELPER_PID_FILE="$CASE_ROOT/helper.pid"
  export SNIPPR_INSTALL_LIBRARY_ONLY=1
  export SNIPPR_INSTALL_TEST_APP="$CASE_ROOT/Snippr.app"
  export SNIPPR_INSTALL_TEST_HEALTH_FILE="$CASE_ROOT/status.txt"
  export SNIPPR_INSTALL_TEST_HEALTH_TIMEOUT=7
  export SNIPPR_INSTALL_TEST_STOP_GRACE=1
  export SNIPPR_INSTALL_TEST_STOP_FORCE=1
  export SNIPPR_INSTALL_TEST_TMP="$CASE_ROOT/tmp"
  export SNIPPR_INSTALL_TEST_GRACEFUL_TOOL="$CASE_ROOT/graceful.sh"
  export SNIPPR_INSTALL_TEST_SIGNAL_TOOL="$CASE_ROOT/signal.sh"
  # shellcheck source=../site/install.sh
  . "$INSTALLER"

  make_app "$BACKUP" old
  /usr/bin/printf '%s\n' "$BACKUP" > "$CASE_ROOT/backup-path"
  ACTIVATED=1
  BACKED_UP=1
  TRANSACTION_STARTED=1
  install_transaction_traps
  # Exercise the real EXIT trap and finish()->rollback() path.
  exit 23
)

assert_failure_case() {
  MODE="$1"
  CASE_ROOT="$ROOT/$MODE"
  mkdir -p "$CASE_ROOT"
  make_app "$CASE_ROOT/Snippr.app" new
  "$CASE_ROOT/Snippr.app/Contents/MacOS/Snippr" 30 &
  /usr/bin/printf '%s\n' "$!" > "$CASE_ROOT/candidate.pid"
  /bin/sleep 0.1
  STARTED_AT="$(/bin/date +%s)"
  if run_failure_case "$MODE"; then
    echo "FAIL site-installer-$MODE expected nonzero transaction" >&2
    exit 1
  fi
  ELAPSED=$(( $(/bin/date +%s) - STARTED_AT ))
  PID="$(sed -n '1p' "$CASE_ROOT/candidate.pid")"
  BACKUP_PATH="$(sed -n '1p' "$CASE_ROOT/backup-path")"
  SIGNALS="$(sed -n '1,20p' "$CASE_ROOT/signals.log" 2>/dev/null || true)"
  HELPER_STARTED=0
  HELPER_SURVIVED=0
  if [ -f "$CASE_ROOT/helper.pid" ]; then
    HELPER_STARTED=1
    HELPER_PID="$(sed -n '1p' "$CASE_ROOT/helper.pid")"
    if /bin/kill -0 "$HELPER_PID" 2>/dev/null; then
      HELPER_SURVIVED=1
      /bin/kill -KILL "$HELPER_PID" 2>/dev/null || true
    fi
  fi
  if [ "$MODE" = "immortal" ]; then
    [ "$(marker "$CASE_ROOT/Snippr.app")" = new ]
    [ "$(marker "$BACKUP_PATH")" = old ]
    /bin/kill -0 "$PID" 2>/dev/null
    /bin/kill -KILL "$PID" 2>/dev/null || true
    /usr/bin/printf '%s' "$SIGNALS" | /usr/bin/grep -Fq -- '--request-terminate-pid'
    /usr/bin/printf '%s' "$SIGNALS" | /usr/bin/grep -Fq -- '-KILL'
  else
    [ "$(marker "$CASE_ROOT/Snippr.app")" = old ]
    [ ! -e "$BACKUP_PATH" ]
    ! /bin/kill -0 "$PID" 2>/dev/null
    /usr/bin/printf '%s' "$SIGNALS" | /usr/bin/grep -Fq -- '--request-terminate-pid'
    if [ "$MODE" = "force" ]; then
      /usr/bin/printf '%s' "$SIGNALS" | /usr/bin/grep -Fq -- '-KILL'
      [ "$HELPER_STARTED" = 1 ]
      [ "$HELPER_SURVIVED" = 0 ]
      [ "$ELAPSED" -lt 10 ]
    else
      ! /usr/bin/printf '%s' "$SIGNALS" | /usr/bin/grep -Fq -- '-KILL'
    fi
  fi
  wait "$PID" 2>/dev/null || true
  echo "PASS site-installer-$MODE"
}

run_health_case() (
  CASE_ROOT="$ROOT/health"
  mkdir -p "$CASE_ROOT"
  make_tools "$CASE_ROOT" polite
  export SNIPPR_TEST_SIGNAL_LOG="$CASE_ROOT/signals.log"
  export SNIPPR_TEST_HELPER_PID_FILE="$CASE_ROOT/helper.pid"
  export SNIPPR_INSTALL_LIBRARY_ONLY=1
  export SNIPPR_INSTALL_TEST_APP="$CASE_ROOT/Snippr.app"
  export SNIPPR_INSTALL_TEST_HEALTH_FILE="$CASE_ROOT/status.txt"
  export SNIPPR_INSTALL_TEST_HEALTH_TIMEOUT=7
  export SNIPPR_INSTALL_TEST_STOP_GRACE=1
  export SNIPPR_INSTALL_TEST_STOP_FORCE=1
  export SNIPPR_INSTALL_TEST_TMP="$CASE_ROOT/tmp"
  export SNIPPR_INSTALL_TEST_GRACEFUL_TOOL="$CASE_ROOT/graceful.sh"
  export SNIPPR_INSTALL_TEST_SIGNAL_TOOL="$CASE_ROOT/signal.sh"
  . "$INSTALLER"

  make_app "$APP" new
  make_app "$BACKUP" old
  "$EXPECTED_EXECUTABLE" 30 &
  PID=$!
  /usr/bin/printf '%s\n' "$PID" > "$CASE_ROOT/candidate.pid"
  CANDIDATE_VERSION=1.2.4
  CANDIDATE_BUILD=21
  ACTIVATED=1
  BACKED_UP=1
  TRANSACTION_STARTED=1
  install_transaction_traps
  /usr/bin/printf 'pid=%s\nversion=1.2.4\nbuild=21\nexecutable=%s\n' \
    "$PID" "$EXPECTED_EXECUTABLE" > "$HEALTH_FILE"
  wait_for_health
  commit_transaction
  [ "$BACKED_UP" = 0 ] && [ "$ACTIVATED" = 0 ] && [ "$TRANSACTION_STARTED" = 0 ]
  [ "$(marker "$APP")" = new ] && [ ! -e "$BACKUP" ]
  /bin/kill -0 "$PID" 2>/dev/null
  /bin/kill -KILL "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
)

assert_failure_case polite
assert_failure_case force
assert_failure_case immortal
run_health_case
echo "PASS site-installer-health-commit"
echo "SITE INSTALLER TRANSACTION TESTS PASSED"
