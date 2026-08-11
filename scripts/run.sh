#!/usr/bin/env bash
# Build once and (re)launch BerryDB for development — no file watching.
# Hot-reload is intentionally off; run this after each change to see the new
# build. Any running dev instance is stopped first so the fresh binary wins.
#
#   scripts/run.sh          # debug build (default)
#   scripts/run.sh release  # optimized build
set -euo pipefail
cd "$(dirname "$0")/.."

# Local dev overrides (e.g. BERRYDB_BACKEND_URL to point at a remote API
# instead of the localhost default) — see .env.example. Never committed.
[ -f .env ] && set -a && source .env && set +a

CONFIG="${1:-debug}"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG"

# Stop a previous dev instance so the new binary takes over the Dock slot.
pkill -x BerryApp 2>/dev/null || true
pkill -x BerryDB 2>/dev/null || true

# Package dist/BerryDB.app so macOS Force Quit, Dock, and process table show AppIcon.icns
scripts/make_app.sh "$CONFIG"

APP_BIN="dist/BerryDB.app/Contents/MacOS/BerryDB"

# Sign with the stable dev identity if it exists so the macOS Keychain keeps
# trusting the app across rebuilds — no password re-prompt on every connect.
# Set it up once with scripts/dev-sign-setup.sh; this is a no-op without it.
if security find-certificate -c "BerryDB Dev" >/dev/null 2>&1; then
    if codesign --force --deep --sign "BerryDB Dev" "dist/BerryDB.app" >/dev/null 2>&1; then
        echo "▸ Signed as \"BerryDB Dev\" (stable Keychain identity)"
    fi
fi

echo "▸ Launching $APP_BIN"
exec "$APP_BIN"
