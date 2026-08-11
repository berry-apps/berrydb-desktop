#!/bin/sh
# App size + runtime-dependency guard (docs/architecture/01 §2, 08 §6).
# The release .app must stay under 100 MB and link ONLY system frameworks and
# the Swift runtime — no bundled Electron/JVM/Qt or other foreign runtime
# (principle: native, zero runtime deps). Fails the build otherwise.
set -eu

LIMIT_MB=100
CONFIG=release
APP="dist/BerryDB.app"
BIN="$APP/Contents/MacOS/BerryDB"

echo "==> Building release + packaging"
swift build -c "$CONFIG" --product BerryApp
sh scripts/make_app.sh "$CONFIG"

# --- Size ---
SIZE_KB=$(du -sk "$APP" | cut -f1)
SIZE_MB=$(( SIZE_KB / 1024 ))
echo "SIZE app=${SIZE_MB} MB (limit ${LIMIT_MB} MB)"

# --- Runtime dependencies ---
# Allow system dylibs (/usr/lib, /System/Library) and the Swift runtime
# (libswift*, including @rpath back-deploy shims). Anything else is a bundled
# foreign runtime and fails the guard.
# Strip the allowed lines (system dylibs + Swift runtime); whatever remains is
# a bundled foreign runtime. `|| true`: grep -v exits 1 when nothing remains.
# Sparkle (auto-update, 10 §3) and libsybdb (FreeTDS DB-Library, SQL Server,
# 16 §1 — LGPL requires dynamic linking, not static) are the two sanctioned
# embedded exceptions, both signed and shipped inside the bundle; everything
# else still fails the guard.
FOREIGN=$(otool -L "$BIN" | tail -n +2 | awk '{print $1}' \
    | grep -v -e '^/usr/lib/' -e '^/System/Library/' -e 'libswift' -e 'Sparkle' -e 'libsybdb' || true)

FAIL=0
if [ "$SIZE_KB" -gt $(( LIMIT_MB * 1024 )) ]; then
    echo "FAIL: app is ${SIZE_MB} MB, over the ${LIMIT_MB} MB target (01 §2)" >&2
    FAIL=1
fi
if [ -n "$FOREIGN" ]; then
    echo "FAIL: non-system runtime dependency linked (01 §2 — no Electron/JVM/Qt):" >&2
    echo "$FOREIGN" | sed 's/^/  /' >&2
    FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
    echo "OK: size + runtime deps within targets"
else
    exit 1
fi
