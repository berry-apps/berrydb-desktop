#!/bin/sh
# Tests for the bundled-helper guard in scripts/check-size.sh. The real script
# runs with SKIP_BUILD=1 from a throwaway directory holding a fixture
# dist/BerryDB.app, whose Mach-O files are tiny real binaries compiled here, so
# otool reads genuine load commands rather than mocked output. Same approach as
# scripts/test-check-minos.sh.
#
# The helper case that matters most is a berrydb-mcp that still loads libsybdb
# from Homebrew: it runs on the build machine and on no user's Mac, so only a
# guard on the packaged bundle catches it.
set -eu

SCRIPT="$(cd "$(dirname "$0")" && pwd)/check-size.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; echo "       $2"; FAILURES=$((FAILURES + 1)); }

MINOS=15.0
HOMEBREW_SYBDB=/opt/homebrew/opt/freetds/lib/libsybdb.5.dylib

# A dylib exporting one symbol, recorded under install name $2.
# $1=output path $2=install name
build_dylib() {
    printf 'int sybdb_fixture(void) { return 1; }\n' > "$TMP/dylib.c"
    clang -dynamiclib -mmacosx-version-min="$MINOS" -install_name "$2" -o "$1" "$TMP/dylib.c"
}

# An executable linked against the dylibs given after any linker flags.
# $1=output path, then extra clang arguments (dylib paths, -Wl,... flags).
build_exe() {
    out="$1"; shift
    printf 'int main(void) { return 0; }\n' > "$TMP/main.c"
    clang -mmacosx-version-min="$MINOS" -o "$out" "$TMP/main.c" "$@"
}

# The two libsybdb stand-ins: the embedded copy make_app.sh produces, and the
# Homebrew original whose install name a helper keeps if nothing rewrites it.
mkdir -p "$TMP/libs"
build_dylib "$TMP/libs/embedded-libsybdb.5.dylib" "@rpath/libsybdb.5.dylib"
build_dylib "$TMP/libs/homebrew-libsybdb.5.dylib" "$HOMEBREW_SYBDB"
build_dylib "$TMP/libs/libother.dylib" "@rpath/libother.dylib"

# A fixture repository root holding dist/BerryDB.app as make_app.sh lays it
# out: main binary and helper both linking the embedded libsybdb through the
# rpath make_app.sh gives each, plus the LGPL texts check-size.sh requires
# whenever libsybdb is linked. Prints the root.
make_repo() {
    root="$TMP/repo"
    rm -rf "$root"
    app="$root/dist/BerryDB.app/Contents"
    mkdir -p "$app/MacOS" "$app/Helpers" "$app/Frameworks" "$app/Resources"
    cp "$TMP/libs/embedded-libsybdb.5.dylib" "$app/Frameworks/libsybdb.5.dylib"
    build_exe "$app/MacOS/BerryDB" "$app/Frameworks/libsybdb.5.dylib" \
        -Wl,-rpath,@loader_path/../Frameworks
    build_exe "$app/Helpers/berrydb-mcp" "$app/Frameworks/libsybdb.5.dylib" \
        -Wl,-rpath,@executable_path/../Frameworks
    : > "$app/Resources/LGPL-2.1.txt"
    : > "$app/Resources/NOTICE-FreeTDS.txt"
    echo "$root"
}

# Runs the real check-size.sh against the fixture in $1; sets OUT and CODE.
run_check() {
    set +e
    OUT="$(cd "$1" && SKIP_BUILD=1 sh "$SCRIPT" 2>&1)"
    CODE=$?
    set -e
}

echo "testing $SCRIPT"

# 1. The bundle make_app.sh produces passes. Every failing case below changes
#    one thing about this fixture, so this case is what makes their failures
#    mean something.
ROOT="$(make_repo)"
run_check "$ROOT"
[ "$CODE" -eq 0 ] \
    && pass "passes a bundle whose helper links libsybdb through @rpath" \
    || fail "passes a bundle whose helper links libsybdb through @rpath" "exit=$CODE out: $OUT"

# 2. A helper still pointing at Homebrew's libsybdb fails, naming the path.
ROOT="$(make_repo)"
build_exe "$ROOT/dist/BerryDB.app/Contents/Helpers/berrydb-mcp" "$TMP/libs/homebrew-libsybdb.5.dylib" \
    -Wl,-rpath,@executable_path/../Frameworks
run_check "$ROOT"
[ "$CODE" -ne 0 ] \
    && pass "fails when the helper links libsybdb from Homebrew" \
    || fail "fails when the helper links libsybdb from Homebrew" "exit=$CODE out: $OUT"
case "$OUT" in
    *berrydb-mcp*"$HOMEBREW_SYBDB"*) pass "failure names the helper and the Homebrew path" ;;
    *) fail "failure names the helper and the Homebrew path" "$OUT" ;;
esac

# 3. A bundle without the helper fails: the settings pane would then offer no
#    way to connect an agent.
ROOT="$(make_repo)"
rm "$ROOT/dist/BerryDB.app/Contents/Helpers/berrydb-mcp"
run_check "$ROOT"
[ "$CODE" -ne 0 ] \
    && pass "fails when the helper is missing" \
    || fail "fails when the helper is missing" "exit=$CODE out: $OUT"
case "$OUT" in
    *Contents/Helpers/berrydb-mcp*) pass "failure names the missing helper path" ;;
    *) fail "failure names the missing helper path" "$OUT" ;;
esac

# 4. The main binary's allowance does not carry over: the helper may link no
#    embedded dylib other than libsybdb.
ROOT="$(make_repo)"
cp "$TMP/libs/libother.dylib" "$ROOT/dist/BerryDB.app/Contents/Frameworks/libother.dylib"
build_exe "$ROOT/dist/BerryDB.app/Contents/Helpers/berrydb-mcp" \
    "$ROOT/dist/BerryDB.app/Contents/Frameworks/libsybdb.5.dylib" \
    "$ROOT/dist/BerryDB.app/Contents/Frameworks/libother.dylib" \
    -Wl,-rpath,@executable_path/../Frameworks
run_check "$ROOT"
[ "$CODE" -ne 0 ] \
    && pass "fails when the helper links another embedded dylib" \
    || fail "fails when the helper links another embedded dylib" "exit=$CODE out: $OUT"
case "$OUT" in
    *@rpath/libother.dylib*) pass "failure names the unexpected dylib" ;;
    *) fail "failure names the unexpected dylib" "$OUT" ;;
esac

# 5. libsybdb referenced through @rpath must actually be in Contents/Frameworks.
ROOT="$(make_repo)"
rm "$ROOT/dist/BerryDB.app/Contents/Frameworks/libsybdb.5.dylib"
run_check "$ROOT"
[ "$CODE" -ne 0 ] \
    && pass "fails when the helper's @rpath dylib is not in Contents/Frameworks" \
    || fail "fails when the helper's @rpath dylib is not in Contents/Frameworks" "exit=$CODE out: $OUT"

# 6. Without an rpath into Contents/Frameworks, @rpath/libsybdb resolves
#    nowhere once the build directory is gone.
ROOT="$(make_repo)"
build_exe "$ROOT/dist/BerryDB.app/Contents/Helpers/berrydb-mcp" \
    "$ROOT/dist/BerryDB.app/Contents/Frameworks/libsybdb.5.dylib"
run_check "$ROOT"
[ "$CODE" -ne 0 ] \
    && pass "fails when the helper has no rpath into Contents/Frameworks" \
    || fail "fails when the helper has no rpath into Contents/Frameworks" "exit=$CODE out: $OUT"
case "$OUT" in
    *@executable_path/../Frameworks*) pass "failure names the expected rpath" ;;
    *) fail "failure names the expected rpath" "$OUT" ;;
esac

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "All check-size tests passed."
else
    echo "$FAILURES test(s) failed."
    exit 1
fi
