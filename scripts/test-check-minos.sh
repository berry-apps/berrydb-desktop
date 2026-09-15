#!/bin/sh
# Tests for scripts/check-minos.sh, run against real (tiny, deliberately
# constructed) Mach-O fixtures rather than mocked otool output -- following
# webapp/deploy/test-deploy-version.sh's precedent of exercising the real
# script against a throwaway sandbox instead of stubbing its inputs.
#
# This exists because of https://github.com/berry-apps/berrydb-desktop/issues/8:
# the release .app's embedded libsybdb.5.dylib was quietly stamped
# LC_BUILD_VERSION minos=15.0 (Homebrew's freetds bottle rebuilt against a
# newer macOS) while the app itself still declares macOS 14.0 -- and nothing
# caught it before it shipped. `ld` printed a warning at build time; nobody
# reads release build logs line by line.
set -eu

SCRIPT="$(cd "$(dirname "$0")" && pwd)/check-minos.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; echo "       $2"; FAILURES=$((FAILURES + 1)); }

# Compiles a minimal, real Mach-O file stamped with the given
# -mmacosx-version-min. $1=output path $2=minos $3=dylib|exe
build_macho() {
    out="$1"; minos="$2"; kind="$3"
    src="$TMP/src-$$-$RANDOM.c"
    if [ "$kind" = dylib ]; then
        printf 'int dummy_symbol(void) { return 42; }\n' > "$src"
        clang -dynamiclib -mmacosx-version-min="$minos" -o "$out" "$src"
    else
        printf 'int main(void) { return 0; }\n' > "$src"
        clang -mmacosx-version-min="$minos" -o "$out" "$src"
    fi
}

# Builds a fake Foo.app/Contents/{MacOS/BerryDB, Frameworks/<dylib fixtures>}
# bundle. $1=app minos; remaining args are "name:minos" pairs to place in
# Frameworks/.
make_bundle() {
    app_minos="$1"; shift
    rm -rf "$TMP/Fixture.app"
    mkdir -p "$TMP/Fixture.app/Contents/MacOS" "$TMP/Fixture.app/Contents/Frameworks"
    build_macho "$TMP/Fixture.app/Contents/MacOS/BerryDB" "$app_minos" exe
    for spec in "$@"; do
        name="${spec%%:*}"; minos="${spec#*:}"
        build_macho "$TMP/Fixture.app/Contents/Frameworks/$name" "$minos" dylib
    done
    echo "$TMP/Fixture.app"
}

echo "testing $SCRIPT"

# 1. A dylib stamped for a HIGHER minOS than the app itself -- exactly the bug:
#    app declares 14.0, the embedded dylib is really 15.0 (like libsybdb was).
BUNDLE="$(make_bundle 14.0 libsybdb.5.dylib:15.0)"
set +e
OUT="$(sh "$SCRIPT" "$BUNDLE" 2>&1)"
CODE=$?
set -e
[ "$CODE" -ne 0 ] \
    && pass "fails when an embedded dylib's minos exceeds the app's" \
    || fail "fails when an embedded dylib's minos exceeds the app's" "exit=$CODE out: $OUT"
case "$OUT" in
    *libsybdb.5.dylib*15.0*14.0*) pass "failure message names the offending file and both versions" ;;
    *) fail "failure message names the offending file and both versions" "$OUT" ;;
esac

# 2. Guard the regression: run the SAME check against a bundle where nothing is
#    mismatched (dylib minos equals the app's) -- confirms case 1 above was
#    actually testing the mismatch, not just "the script always fails".
BUNDLE="$(make_bundle 14.0 libsybdb.5.dylib:14.0)"
set +e
OUT="$(sh "$SCRIPT" "$BUNDLE" 2>&1)"
CODE=$?
set -e
[ "$CODE" -eq 0 ] \
    && pass "passes when the embedded dylib's minos matches the app's" \
    || fail "passes when the embedded dylib's minos matches the app's" "exit=$CODE out: $OUT"

# 3. A dylib stamped LOWER than the app's own minimum is fine (a dependency
#    that supports MORE OS versions than we promise is not a problem).
BUNDLE="$(make_bundle 14.0 libsybdb.5.dylib:13.0)"
set +e
OUT="$(sh "$SCRIPT" "$BUNDLE" 2>&1)"
CODE=$?
set -e
[ "$CODE" -eq 0 ] \
    && pass "passes when the embedded dylib's minos is lower than the app's" \
    || fail "passes when the embedded dylib's minos is lower than the app's" "exit=$CODE out: $OUT"

# 4. A nested framework bundle (Sparkle.framework/Versions/.../Sparkle style),
#    not a loose Contents/Frameworks/*.dylib -- the check must recurse, since
#    Sparkle itself ships this way.
BUNDLE="$(make_bundle 14.0)"
mkdir -p "$BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"
build_macho "$BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" 15.0 dylib
set +e
OUT="$(sh "$SCRIPT" "$BUNDLE" 2>&1)"
CODE=$?
set -e
[ "$CODE" -ne 0 ] \
    && pass "recurses into nested .framework bundles" \
    || fail "recurses into nested .framework bundles" "exit=$CODE out: $OUT"

# 5. No Frameworks/ dir at all (a build with nothing embedded) must pass --
#    there is nothing to compare against, not a violation.
rm -rf "$TMP/Fixture.app"
mkdir -p "$TMP/Fixture.app/Contents/MacOS"
build_macho "$TMP/Fixture.app/Contents/MacOS/BerryDB" 14.0 exe
set +e
OUT="$(sh "$SCRIPT" "$TMP/Fixture.app" 2>&1)"
CODE=$?
set -e
[ "$CODE" -eq 0 ] \
    && pass "passes when there is no Frameworks/ directory at all" \
    || fail "passes when there is no Frameworks/ directory at all" "exit=$CODE out: $OUT"

# 6. A bundle whose main binary is missing entirely refuses to check anything,
#    rather than silently reporting success.
set +e
OUT="$(sh "$SCRIPT" "$TMP/does-not-exist.app" 2>&1)"
CODE=$?
set -e
[ "$CODE" -ne 0 ] \
    && pass "refuses (does not silently pass) when the main binary is missing" \
    || fail "refuses (does not silently pass) when the main binary is missing" "exit=$CODE out: $OUT"

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "All check-minos tests passed."
else
    echo "$FAILURES test(s) failed."
    exit 1
fi
