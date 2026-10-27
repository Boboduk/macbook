#!/usr/bin/env bash
# Launch smoke test for a Debug build (used by CI, also runnable locally).
#
#   Scripts/ci-smoke-test.sh path/to/AlcoveInspired.app output-dir
#
# 1. Launches the app idle and measures CPU / memory after it settles.
# 2. Relaunches it once per island state (--ui-test-state, Debug only),
#    checks that it keeps running and takes a screenshot.
# 3. Fails if the app exits early or a crash report appears.
set -uo pipefail

APP="$1"
OUT="$2"
mkdir -p "$OUT"
BIN="$APP/Contents/MacOS/AlcoveInspired"
BUNDLE_ID="$(defaults read "$(cd "$APP" && pwd)/Contents/Info" CFBundleIdentifier)"
REPORTS="$HOME/Library/Logs/DiagnosticReports"
failures=0

# Start from default settings.
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
before_reports="$(ls "$REPORTS" 2>/dev/null | grep -c AlcoveInspired || true)"

echo "== Idle resource usage"
"$BIN" >"$OUT/idle.log" 2>&1 &
pid=$!
sleep 12
if kill -0 "$pid" 2>/dev/null; then
  # The second sample of `top` reflects the last interval only.
  top -l 2 -s 3 -pid "$pid" -stats pid,command,cpu,mem,threads | tail -2 | tee "$OUT/idle-usage.txt"
  screencapture -x "$OUT/idle.png" 2>/dev/null || echo "(screencapture unavailable)"
  kill "$pid"; wait "$pid" 2>/dev/null
else
  echo "::error::App exited while idle"; cat "$OUT/idle.log"; failures=$((failures + 1))
fi

for state in expanded-music expanded-timer hud-volume hud-brightness banner-notice timer-compact settings; do
  echo "== State: $state"
  "$BIN" --ui-test-state "$state" >"$OUT/$state.log" 2>&1 &
  pid=$!
  sleep 3
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "::error::App exited early in state $state"
    cat "$OUT/$state.log"
    failures=$((failures + 1))
    continue
  fi
  screencapture -x "$OUT/$state.png" 2>/dev/null || echo "(screencapture unavailable)"
  kill "$pid"; wait "$pid" 2>/dev/null
done

after_reports="$(ls "$REPORTS" 2>/dev/null | grep -c AlcoveInspired || true)"
if [[ "$after_reports" -gt "$before_reports" ]]; then
  echo "::error::Crash report(s) found"
  ls "$REPORTS" | grep AlcoveInspired
  cp "$REPORTS"/AlcoveInspired* "$OUT/" 2>/dev/null || true
  failures=$((failures + 1))
fi

defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
echo "Smoke test failures: $failures"
exit "$failures"
