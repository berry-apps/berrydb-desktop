#!/usr/bin/env bash
# Build once and launch BerryDB under LLDB with automatic backtrace
# on AppKit NSTableRowHeightData reentrancy.
# Full output is mirrored to .build/reentrancy_trace.log for analysis.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] && set -a && source .env && set +a

CONFIG="${1:-debug}"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG"

pkill -x BerryApp 2>/dev/null || true
pkill -x BerryDB 2>/dev/null || true

scripts/make_app.sh "$CONFIG"

APP_BIN="dist/BerryDB.app/Contents/MacOS/BerryDB"

if security find-certificate -c "BerryDB Dev" >/dev/null 2>&1; then
    if codesign --force --deep --sign "BerryDB Dev" "dist/BerryDB.app" >/dev/null 2>&1; then
        echo "▸ Signed as \"BerryDB Dev\" (stable Keychain identity)"
    fi
fi

mkdir -p dist
TRACE_LOG="$(pwd)/reentrancy_trace.log"
rm -f "$TRACE_LOG"

echo "▸ Log file will be saved to: $TRACE_LOG"
echo "▸ Launching $APP_BIN under LLDB with auto-trace on reentrancy warning…"

xcrun lldb --batch \
  -o "target create $APP_BIN" \
  -o 'breakpoint set -n NSLog -C "bt 40" -G1' \
  -o 'breakpoint set -n NSLogv -C "bt 40" -G1' \
  -o "process launch" 2>&1 | tee "$TRACE_LOG"
