#!/bin/zsh
# Dev watch loop: rebuild + relaunch BerryApp whenever Swift sources change,
# with a macOS notification on build failures so the app's current state is
# always visible while developing.
#
# Usage: make watch   (Ctrl-C to stop)
#
# Uses fswatch when available (event-driven); falls back to 1s polling with
# zero extra dependencies.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Local dev overrides (e.g. BERRYDB_BACKEND_URL to point at a remote API
# instead of the localhost default) — see .env.example. Never committed.
[ -f .env ] && set -a && source .env && set +a

BIN="dist/BerryDB.app/Contents/MacOS/BerryDB"
APP_PID=""
WATCH_PATHS=(App Packages Package.swift)

notify() {
    # $1 = title, $2 = body
    osascript -e "display notification \"$2\" with title \"BerryDB build\" subtitle \"$1\"" >/dev/null 2>&1 || true
}

kill_app() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null
        wait "$APP_PID" 2>/dev/null
    fi
    APP_PID=""
}

launch_app() {
    "$BIN" >/dev/null 2>&1 &
    APP_PID=$!
}

build_and_run() {
    local started=$(date +%s)
    if OUTPUT=$(swift build 2>&1); then
        scripts/make_app.sh debug >/dev/null 2>&1
        local took=$(( $(date +%s) - started ))
        echo "\033[32m✔ build OK (${took}s) — relaunching app\033[0m"
        kill_app
        launch_app
    else
        local errors=$(echo "$OUTPUT" | grep -c "error:")
        echo "\033[31m✘ build FAILED (${errors} lỗi)\033[0m"
        echo "$OUTPUT" | grep -E "error:" | head -10
        notify "FAILED" "${errors} lỗi biên dịch — app giữ phiên bản cũ"
        # Keep the previous app running so the last good state stays visible.
    fi
}

cleanup() {
    kill_app
    exit 0
}
trap cleanup INT TERM

echo "BerryDB dev watch — theo dõi: ${WATCH_PATHS[*]} (Ctrl-C để dừng)"
build_and_run

if command -v fswatch >/dev/null 2>&1; then
    fswatch -o -l 0.5 -e '\.build' "${WATCH_PATHS[@]}" | while read -r _; do
        build_and_run
    done
else
    # Polling fallback: a stamp file marks the last build; any newer .swift
    # file (or Package.swift) triggers a rebuild.
    STAMP=".build/.watch-stamp"
    mkdir -p .build && touch "$STAMP"
    while true; do
        sleep 1
        CHANGED=$(find "${WATCH_PATHS[@]}" -name '*.swift' -newer "$STAMP" 2>/dev/null | head -1)
        if [ -n "$CHANGED" ]; then
            echo "— thay đổi: $CHANGED"
            touch "$STAMP"
            build_and_run
        fi
    done
fi
