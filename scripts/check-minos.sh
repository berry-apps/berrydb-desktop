#!/bin/sh
# Guards against an embedded Contents/Frameworks/ dylib declaring a higher
# LC_BUILD_VERSION/LC_VERSION_MIN_MACOSX minos than the app's own main binary.
#
# This is the exact drift behind
# https://github.com/berry-apps/berrydb-desktop/issues/8: Homebrew rebuilds the
# `freetds` bottle against whatever macOS the build machine is running, which
# only ever moves forward, so the embedded libsybdb.5.dylib quietly picked up a
# macOS 15.0 floor while BerryDB itself still declared macOS 14.0. `ld`
# already warned about this at build time
# ("building for macOS-14.0, but linking with dylib ... built for newer
# version 15.0") but nothing failed the build on it, so the warning went
# unnoticed until a real release shipped with the mismatch.
#
# The MAIN BINARY's own compiled minos -- not Info.plist's
# LSMinimumSystemVersion -- is the baseline: it is the value `ld` actually
# compared the dylib's minos against to produce that warning, and it comes
# straight from the compiled artifact rather than a separately hand-maintained
# plist string (LSMinimumSystemVersion is written as a literal in
# scripts/make_app.sh) that could itself drift out of sync with what was
# really built.
#
# Usage: scripts/check-minos.sh [path/to/Foo.app]   (default: dist/BerryDB.app)
set -eu

APP="${1:-dist/BerryDB.app}"
BIN="$APP/Contents/MacOS/BerryDB"

[ -f "$BIN" ] || { echo "FAIL: main binary not found at $BIN" >&2; exit 1; }

# Prints every LC_BUILD_VERSION/LC_VERSION_MIN_MACOSX minos value found in a
# Mach-O file -- one per line, one per architecture slice for a universal
# binary. Empty output means the file carries neither load command (not a
# Mach-O, or a Mach-O with no declared minimum, e.g. a raw object file).
minos_values() {
    otool -l "$1" 2>/dev/null | awk '
        /LC_BUILD_VERSION/      { mode = "bv"; next }
        /LC_VERSION_MIN_MACOSX/ { mode = "vm"; next }
        mode == "bv" && /^ *minos/   { print $2; mode = ""; next }
        mode == "vm" && /^ *version/ { print $2; mode = ""; next }
    '
}

# Highest minos declared across all slices of a file; empty if none found.
max_minos() {
    v="$(minos_values "$1")"
    [ -n "$v" ] || return 0
    printf '%s\n' "$v" | sort -V | tail -1
}

APP_MINOS="$(max_minos "$BIN")"
[ -n "$APP_MINOS" ] || {
    echo "FAIL: could not read a minimum OS version (LC_BUILD_VERSION/LC_VERSION_MIN_MACOSX) from $BIN" >&2
    exit 1
}

FRAMEWORKS="$APP/Contents/Frameworks"
MISMATCHES="$(mktemp)"
FILELIST="$(mktemp)"
trap 'rm -f "$MISMATCHES" "$FILELIST"' EXIT

if [ -d "$FRAMEWORKS" ]; then
    # -type f (not symlinks) so e.g. libsybdb.dylib -> libsybdb.5.dylib is
    # followed to the one real file instead of double-reported, and so a
    # nested bundle's real binary (Sparkle.framework/Versions/B/Sparkle) is
    # found rather than only the top-level .framework directory.
    find "$FRAMEWORKS" -type f > "$FILELIST"
    while IFS= read -r f; do
        DEP_MINOS="$(max_minos "$f")"
        [ -n "$DEP_MINOS" ] || continue
        HIGHER="$(printf '%s\n%s\n' "$APP_MINOS" "$DEP_MINOS" | sort -V | tail -1)"
        if [ "$HIGHER" = "$DEP_MINOS" ] && [ "$DEP_MINOS" != "$APP_MINOS" ]; then
            echo "  ${f#"$APP"/} declares minos $DEP_MINOS, higher than the app's own $APP_MINOS" >> "$MISMATCHES"
        fi
    done < "$FILELIST"
fi

if [ -s "$MISMATCHES" ]; then
    echo "FAIL: embedded dylib(s) declare a higher minimum OS than $BIN itself (minos $APP_MINOS):" >&2
    cat "$MISMATCHES" >&2
    echo "  Either rebuild/repin the dependency for the app's own minimum OS, or raise" >&2
    echo "  the app's declared minimum (Package.swift, LSMinimumSystemVersion, README.md," >&2
    echo "  webapp/) to match reality." >&2
    exit 1
fi

echo "OK: all embedded Frameworks/ dylibs declare minos <= app's own $APP_MINOS"
