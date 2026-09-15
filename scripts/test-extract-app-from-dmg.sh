#!/bin/sh
# Tests for scripts/extract-app-from-dmg.sh. Builds a REAL throwaway DMG with
# hdiutil (not a mock) and mounts it for real, since the thing worth testing is
# the mount/find/copy/detach sequence itself, not a stub standing in for it.
set -eu

SCRIPT="$(cd "$(dirname "$0")" && pwd)/extract-app-from-dmg.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; echo "       $2"; FAILURES=$((FAILURES + 1)); }

# Build a small DMG containing Fake.app/Contents/MacOS/marker, the way a real
# release DMG contains BerryDB.app.
make_dmg() {
    dmg_path="$1"
    staging="$TMP/staging-$(basename "$dmg_path" .dmg)"
    rm -rf "$staging"
    mkdir -p "$staging/Fake.app/Contents/MacOS"
    echo "$2" > "$staging/Fake.app/Contents/MacOS/marker"
    hdiutil create -volname "Fake" -srcfolder "$staging" -ov -format UDZO "$dmg_path" -quiet
}

# 1. Happy path: the .app bundle is copied out with its contents intact.
DMG1="$TMP/one.dmg"
make_dmg "$DMG1" "hello-from-one"
DEST1="$TMP/extracted/One.app"
sh "$SCRIPT" "$DMG1" "$DEST1" >"$TMP/out1" 2>&1
if [ -f "$DEST1/Contents/MacOS/marker" ] && [ "$(cat "$DEST1/Contents/MacOS/marker")" = "hello-from-one" ]; then
    pass "extracts the .app with its file contents intact"
else
    fail "extracts the .app with its file contents intact" "$(cat "$TMP/out1")"
fi

# 2. The DMG must actually be detached afterwards -- a leaked mount on a CI
#    runner processing several old versions would eventually run it out of
#    mount points.
if hdiutil info | grep -q "$DMG1"; then
    fail "detaches the DMG when done" "still mounted after the script exited"
else
    pass "detaches the DMG when done"
fi

# 3. Re-running into the same destination overwrites cleanly rather than
#    merging with a previous extraction (relevant since work_dir is reused
#    across delta candidates in generate_deltas).
DMG2="$TMP/two.dmg"
make_dmg "$DMG2" "hello-from-two"
sh "$SCRIPT" "$DMG2" "$DEST1" >"$TMP/out2" 2>&1
if [ "$(cat "$DEST1/Contents/MacOS/marker" 2>/dev/null)" = "hello-from-two" ]; then
    pass "overwrites a pre-existing destination"
else
    fail "overwrites a pre-existing destination" "$(cat "$TMP/out2")"
fi

# 4. Missing source file: fail loudly rather than mounting garbage.
set +e
sh "$SCRIPT" "$TMP/does-not-exist.dmg" "$TMP/never.app" >"$TMP/out3" 2>&1
CODE=$?
set -e
[ "$CODE" -ne 0 ] && pass "missing DMG: exits non-zero" || fail "missing DMG: exits non-zero" "exit=$CODE"

# 5. A DMG with no .app bundle inside: fail rather than silently produce an
#    empty/garbage destination.
EMPTY_STAGING="$TMP/empty-staging"
mkdir -p "$EMPTY_STAGING"
echo "not an app" > "$EMPTY_STAGING/readme.txt"
EMPTY_DMG="$TMP/empty.dmg"
hdiutil create -volname "Empty" -srcfolder "$EMPTY_STAGING" -ov -format UDZO "$EMPTY_DMG" -quiet
set +e
sh "$SCRIPT" "$EMPTY_DMG" "$TMP/never2.app" >"$TMP/out4" 2>&1
CODE=$?
set -e
[ "$CODE" -ne 0 ] && pass "no .app in the DMG: exits non-zero" || fail "no .app in the DMG: exits non-zero" "exit=$CODE"
[ -e "$TMP/never2.app" ] && fail "no .app in the DMG: leaves no destination" "destination was created anyway" \
    || pass "no .app in the DMG: leaves no destination"

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "All extract-app-from-dmg tests passed."
else
    echo "$FAILURES test(s) failed."
    exit 1
fi
