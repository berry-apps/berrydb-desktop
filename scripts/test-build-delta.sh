#!/bin/sh
# Tests for scripts/build-delta.sh. Every case uses a stub standing in for
# Sparkle's BinaryDelta (mirrors scripts/test-sign-update.sh's approach for
# sign_update) so nothing here needs a real Sparkle checkout or actually diffs
# anything.
set -eu

SCRIPT="$(cd "$(dirname "$0")" && pwd)/build-delta.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; echo "       $2"; FAILURES=$((FAILURES + 1)); }

OLD_APP="$TMP/Old.app"
NEW_APP="$TMP/New.app"
mkdir -p "$OLD_APP" "$NEW_APP"
OUT="$TMP/out.delta"

# A stub standing in for BinaryDelta. Echoes its arguments to $TMP/args and
# writes some bytes to the patch file path it was given, the way a real
# `BinaryDelta create` would leave a patch file behind.
STUB="$TMP/BinaryDelta"
cat > "$STUB" <<'STUB_EOF'
#!/bin/sh
printf '%s\n' "$*" > "$(dirname "$0")/args"
# $4 is the patch file argument (create <old> <new> <patch>).
echo "fake-patch-bytes" > "$4"
STUB_EOF
chmod +x "$STUB"

# 1. Happy path: invokes BinaryDelta as "create <old> <new> <out>" and leaves
#    the patch file behind.
BINARY_DELTA_BIN="$STUB" sh "$SCRIPT" "$OLD_APP" "$NEW_APP" "$OUT" >"$TMP/o1" 2>&1
ARGS="$(cat "$TMP/args" 2>/dev/null || true)"
case "$ARGS" in
  "create $OLD_APP $NEW_APP $OUT") pass "invokes BinaryDelta as create <old> <new> <out>" ;;
  *) fail "invokes BinaryDelta as create <old> <new> <out>" "args were: $ARGS" ;;
esac
[ -f "$OUT" ] && pass "leaves the patch file behind" || fail "leaves the patch file behind" "missing $OUT"

# 2. A stale output file from a previous attempt must not survive untouched if
#    BinaryDelta is re-run and fails -- rm -f before the tool runs.
echo "stale" > "$OUT"
FAILING="$TMP/BinaryDeltaFailing"
cat > "$FAILING" <<'STUB_EOF'
#!/bin/sh
exit 1
STUB_EOF
chmod +x "$FAILING"
set +e
BINARY_DELTA_BIN="$FAILING" sh "$SCRIPT" "$OLD_APP" "$NEW_APP" "$OUT" >"$TMP/o2" 2>&1
CODE=$?
set -e
[ "$CODE" -ne 0 ] && pass "a failing BinaryDelta exits non-zero" \
  || fail "a failing BinaryDelta exits non-zero" "exit=$CODE"
[ ! -f "$OUT" ] && pass "removes a stale output before a failed run" \
  || fail "removes a stale output before a failed run" "$(cat "$OUT")"

# 3. BinaryDelta not found (no BINARY_DELTA_BIN, none under .build here): exits
#    with the distinct code 2 so the caller can stop trying entirely rather
#    than treat it as one failed pair among many.
set +e
BINARY_DELTA_BIN="$TMP/does-not-exist" sh "$SCRIPT" "$OLD_APP" "$NEW_APP" "$OUT" >"$TMP/o3" 2>"$TMP/e3"
CODE=$?
set -e
[ "$CODE" -eq 2 ] && pass "missing tool: exits with code 2" \
  || fail "missing tool: exits with code 2" "exit=$CODE"
grep -qi "not found" "$TMP/e3" && pass "missing tool: explains why on stderr" \
  || fail "missing tool: explains why on stderr" "stderr: $(cat "$TMP/e3")"

# 4. Old/new paths that are not directories: fail before ever invoking the tool.
set +e
BINARY_DELTA_BIN="$STUB" sh "$SCRIPT" "$TMP/nope.app" "$NEW_APP" "$OUT" >"$TMP/o4" 2>&1
CODE=$?
set -e
[ "$CODE" -ne 0 ] && pass "rejects a non-directory old app" \
  || fail "rejects a non-directory old app" "exit=$CODE"

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "All build-delta tests passed."
else
    echo "$FAILURES test(s) failed."
    exit 1
fi
