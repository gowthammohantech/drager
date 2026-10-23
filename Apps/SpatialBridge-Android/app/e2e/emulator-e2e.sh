#!/usr/bin/env bash
# Emulator end-to-end run (XP2a): Android app (real core, real UI) -> `sb-swift serve` on the host.
#
#   app/e2e/emulator-e2e.sh [--bind 127.0.0.1|0.0.0.0] [--serve PATH_TO_sb-swift] [--keep-emulator]
#
# Boots the Pixel_7_Pro AVD headless if no emulator is attached, installs the debug app and its test
# APK, starts `serve` with auto-approve, runs EmulatorE2ETest with the serve ports, then checks:
#   - the SAS the app showed equals serve's `sas` event
#   - serve printed `committed` with the same sha256 as the source file, and the UI reached Committed
#   - the unsafe type (run.sh) and the 0-byte file both failed with E006 and showed no success
# Shuts the emulator down at the end (unless it was already running or --keep-emulator).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ANDROID_ROOT="$(cd "$HERE/../.." && pwd)"
REPO="$(cd "$ANDROID_ROOT/../.." && pwd)"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
EMULATOR="$SDK/emulator/emulator"
AVD="${AVD:-Pixel_7_Pro}"
BIND="127.0.0.1"
SERVE_BIN="$REPO/Conformance/SwiftHarness/.build/out/Products/Release/sb-swift"
KEEP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bind) BIND="$2"; shift 2 ;;
    --serve) SERVE_BIN="$2"; shift 2 ;;
    --keep-emulator) KEEP=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sb-e2e.XXXXXX")"
SERVE_LOG="$WORK/serve.jsonl"
INSTR_LOG="$WORK/instrument.txt"
STARTED_EMULATOR=0
SERVE_PID=""

cleanup() {
  [[ -n "$SERVE_PID" ]] && kill "$SERVE_PID" 2>/dev/null || true
  if [[ $STARTED_EMULATOR -eq 1 && $KEEP -eq 0 ]]; then
    "$ADB" emu kill >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

[[ -x "$SERVE_BIN" ]] || { echo "sb-swift not found; build it: swift build -c release --package-path Conformance/SwiftHarness" >&2; exit 1; }

if ! "$ADB" devices | grep -q '^emulator-.*device$'; then
  echo "== booting $AVD (headless)"
  "$EMULATOR" -avd "$AVD" -no-window -no-audio -no-boot-anim -no-snapshot-save >"$WORK/emulator.log" 2>&1 &
  STARTED_EMULATOR=1
  "$ADB" wait-for-device
  until [[ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do sleep 2; done
fi

echo "== installing app + test APKs"
(cd "$ANDROID_ROOT" && ./gradlew -q :app:installDebug :app:installDebugAndroidTest)

echo "== starting sb-swift serve on $BIND"
mkdir -p "$WORK/state" "$WORK/dest"
"$SERVE_BIN" serve --state "$WORK/state" --listen "$BIND:0" --dest "$WORK/dest" --decision approve >"$SERVE_LOG" 2>"$WORK/serve.err" &
SERVE_PID=$!
for _ in $(seq 1 50); do grep -q '"listening"' "$SERVE_LOG" 2>/dev/null && break; sleep 0.2; done
LISTEN="$(grep '"listening"' "$SERVE_LOG" | head -1)"
PAIRING_PORT="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["pairingPort"])' "$LISTEN")"
SESSION_PORT="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["sessionPort"])' "$LISTEN")"
echo "   pairingPort=$PAIRING_PORT sessionPort=$SESSION_PORT (emulator dials 10.0.2.2)"

echo "== running EmulatorE2ETest"
set +e
"$ADB" shell am instrument -w -r \
  -e class com.spatialbridge.android.EmulatorE2ETest \
  -e sbHost 10.0.2.2 -e sbPairingPort "$PAIRING_PORT" -e sbSessionPort "$SESSION_PORT" \
  com.gowthammohan.spatialbridge.android.test/androidx.test.runner.AndroidJUnitRunner >"$INSTR_LOG" 2>&1
set -e
sleep 1

status() { grep -E "^INSTRUMENTATION_STATUS: $1=" "$INSTR_LOG" | head -1 | sed -E "s/^INSTRUMENTATION_STATUS: $1=//" | tr -d '\r'; }
APP_SAS="$(status sas)"
APP_SHA="$(status sourceSha256)"
APP_BYTES="$(status sourceBytes)"
SERVE_SAS="$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    e=json.loads(l)
    if e.get("event")=="sas": print(e["code"]); break' "$SERVE_LOG")"
read -r SERVE_SHA SERVE_BYTES < <(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    e=json.loads(l)
    if e.get("event")=="committed": print(e["sha256Hex"], e["byteCount"]); break' "$SERVE_LOG") || true
SERVE_ERRORS="$(python3 -c 'import json,sys
print(" ".join(e["code"] for e in map(json.loads, open(sys.argv[1])) if e.get("event")=="error"))' "$SERVE_LOG")"

fail=0
check() { if [[ "$2" == "$3" && -n "$2" ]]; then echo "PASS $1 ($2)"; else echo "FAIL $1: app='$2' serve='$3'"; fail=1; fi; }
echo "== results (bind $BIND)"
check "SAS shown == serve sas" "$APP_SAS" "$SERVE_SAS"
check "sha256 source == serve committed" "$APP_SHA" "${SERVE_SHA:-}"
check "byteCount source == serve committed" "$APP_BYTES" "${SERVE_BYTES:-}"
check "UI reached Committed" "$(status committed)" "true"
check "unsafe type failed" "$(status unsafeType)" "E006"
check "0-byte file failed" "$(status emptyFile)" "E006"
echo "   serve error events: ${SERVE_ERRORS:-none}"
echo "   serve committed events: $(grep -c '"committed"' "$SERVE_LOG" || true)"
if grep -q "FAILURES!!!\|INSTRUMENTATION_FAILED\|shortMsg=" "$INSTR_LOG" || ! grep -q "^OK (1 test)" "$INSTR_LOG"; then
  echo "FAIL instrumentation (see $INSTR_LOG)"; grep -E "^(OK|FAILURES|Tests run|INSTRUMENTATION_STATUS: stack=)" "$INSTR_LOG" | head -5; fail=1
else
  echo "PASS instrumentation: $(grep '^OK' "$INSTR_LOG")"
fi
echo "   logs: $WORK"
exit $fail
