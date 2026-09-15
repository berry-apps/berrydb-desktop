#!/bin/sh
# App size + runtime-dependency guard.
# The release .app must stay under 200 MB and link ONLY system frameworks and
# the Swift runtime — no bundled Electron/JVM/Qt or other foreign runtime
# (principle: native, zero runtime deps). Fails the build otherwise.
set -eu

LIMIT_MB=200
CONFIG=release
APP="dist/BerryDB.app"
BIN="$APP/Contents/MacOS/BerryDB"

# SKIP_BUILD=1 checks the bundle already on disk. The release pipeline sets it
# because release.sh has just built and signed that exact bundle, and rebuilding
# would both waste a full release compile and check a different artifact from the
# one being published.
if [ -n "${SKIP_BUILD:-}" ]; then
    echo "==> Checking the existing $APP (SKIP_BUILD=1)"
    [ -d "$APP" ] || { echo "FAIL: $APP does not exist — nothing to check" >&2; exit 1; }
else
    echo "==> Building release + packaging"
    swift build -c "$CONFIG" --product BerryApp
    sh scripts/make_app.sh "$CONFIG"
fi

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
# Sparkle (auto-update) and libsybdb (FreeTDS DB-Library, SQL Server,
# LGPL requires dynamic linking, not static) are the two sanctioned
# embedded exceptions, both signed and shipped inside the bundle; everything
# else still fails the guard.
FOREIGN=$(otool -L "$BIN" | tail -n +2 | awk '{print $1}' \
    | grep -v -e '^/usr/lib/' -e '^/System/Library/' -e 'libswift' -e 'Sparkle' -e 'libsybdb' || true)

# --- LGPL notices ---
# libsybdb (FreeTDS DB-Library) is LGPL-2.1 and dynamically linked. Shipping the
# bundle without its licence texts is a licence violation, so this is a hard gate,
# not a warning. Conditional on the library actually being embedded: a build
# without FreeTDS linked owes no notice.
NOTICE_MISSING=""
FREETDS_MISMATCH=""
if otool -L "$BIN" | grep -q 'libsybdb'; then
    for notice in LGPL-2.1.txt NOTICE-FreeTDS.txt; do
        [ -f "$APP/Contents/Resources/$notice" ] || NOTICE_MISSING="$NOTICE_MISSING $notice"
    done

    # LGPL 6(a)/6(d) require offering the source of the exact version shipped, so
    # the version must be the one we publish a tarball for — not whatever Homebrew
    # happened to have linked on the build machine. Without this the shipped
    # version drifts silently every time upstream releases.
    PINNED="$(cat deploy/freetds-version.txt 2>/dev/null | tr -d '[:space:]')"
    EMBEDDED="$(strings "$APP/Contents/Frameworks/libsybdb.5.dylib" 2>/dev/null \
        | grep -oE 'freetds v[0-9]+\.[0-9]+\.[0-9]+' | sed 's/freetds v//' | sort -u | head -1)"
    if [ -n "$PINNED" ] && [ "$PINNED" != "$EMBEDDED" ]; then
        FREETDS_MISMATCH="pinned=$PINNED embedded=${EMBEDDED:-none}"
    fi
fi

# --- Embedded dylib minimum-OS drift (see scripts/check-minos.sh) ---
# A dependency's bottle (freetds/libsybdb today, potentially others later) gets
# rebuilt by Homebrew against whatever macOS the build machine runs, which only
# ever moves forward, and can end up declaring a higher minimum OS than the app
# itself without anyone noticing (issue #8: `ld` warned about exactly this at
# build time and nothing failed the build on it).
MINOS_FAIL=0
sh "$(dirname "$0")/check-minos.sh" "$APP" || MINOS_FAIL=1

FAIL=0
if [ "$SIZE_KB" -gt $(( LIMIT_MB * 1024 )) ]; then
    echo "FAIL: app is ${SIZE_MB} MB, over the ${LIMIT_MB} MB target" >&2
    FAIL=1
fi
if [ -n "$FOREIGN" ]; then
    echo "FAIL: non-system runtime dependency linked (no Electron/JVM/Qt):" >&2
    echo "$FOREIGN" | sed 's/^/  /' >&2
    FAIL=1
fi

if [ -n "$NOTICE_MISSING" ]; then
    echo "FAIL: bundle links libsybdb (LGPL-2.1) but is missing licence texts:" >&2
    for n in $NOTICE_MISSING; do echo "  Contents/Resources/$n" >&2; done
    FAIL=1
fi

if [ -n "$FREETDS_MISMATCH" ]; then
    echo "FAIL: shipped FreeTDS is not the pinned version ($FREETDS_MISMATCH)." >&2
    echo "  Either 'brew upgrade freetds' to match, or bump deploy/freetds-version.txt" >&2
    echo "  and publish the matching source tarball with the next release." >&2
    FAIL=1
fi

if [ "$MINOS_FAIL" -ne 0 ]; then
    FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
    echo "OK: size + runtime deps within targets"
else
    exit 1
fi
