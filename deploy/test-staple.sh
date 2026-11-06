#!/bin/sh
# Tests for deploy/staple.sh. Every case uses a stub xcrun, so nothing here
# notarizes, staples or reaches the network; the whole file runs in about a second.
set -eu
LIB="$(cd "$(dirname "$0")" && pwd)/staple.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; echo "       $2"; FAILURES=$((FAILURES + 1)); }

# A stub xcrun: `xcrun stapler <action> <path>` appends the action to
# $TMP/calls and fails the first $FAIL_STAPLES staple calls and the first
# $FAIL_VALIDATES validate calls (counted in $TMP/<action>.count).
STUB_DIR="$TMP/bin"; mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/xcrun" <<'STUB_EOF'
#!/bin/sh
action="$2"; dir="$(dirname "$0")/.."
echo "$action" >> "$dir/calls"
count_file="$dir/$action.count"; n=0; [ -f "$count_file" ] && n="$(cat "$count_file")"
echo $((n + 1)) > "$count_file"
limit=0
case "$action" in
  staple) limit="${FAIL_STAPLES:-0}" ;;
  validate) limit="${FAIL_VALIDATES:-0}" ;;
esac
if [ "$n" -lt "$limit" ]; then echo "The $action action failed! Error 68." >&2; exit 68; fi
exit 0
STUB_EOF
chmod +x "$STUB_DIR/xcrun"
export PATH="$STUB_DIR:$PATH" STAPLE_RETRY_DELAY=0 STAPLE_ATTEMPTS=4

run_case() { # run_case <fail_staples> <fail_validates> -> exit status in $STATUS, calls in $CALLS
  rm -f "$TMP/calls" "$TMP/staple.count" "$TMP/validate.count"
  set +e
  (FAIL_STAPLES="$1" FAIL_VALIDATES="$2"; export FAIL_STAPLES FAIL_VALIDATES; . "$LIB"; staple_and_validate "$TMP/BerryDB.app") >"$TMP/out" 2>&1
  STATUS=$?
  set -e
  CALLS="$(tr '\n' ' ' < "$TMP/calls" 2>/dev/null || true)"
}

run_case 0 0
if [ "$STATUS" -eq 0 ] && [ "$CALLS" = "staple validate " ]; then pass "a clean run staples and validates once"; else fail "a clean run staples and validates once" "status=$STATUS calls=$CALLS"; fi

run_case 0 2
if [ "$STATUS" -eq 0 ] && [ "$CALLS" = "staple validate staple validate staple validate " ]; then pass "a validate that drops the connection twice is retried until it passes"; else fail "a validate that drops the connection twice is retried until it passes" "status=$STATUS calls=$CALLS"; fi

run_case 1 0
if [ "$STATUS" -eq 0 ] && [ "$CALLS" = "staple staple validate " ]; then pass "a staple that drops the connection is retried without validating in between"; else fail "a staple that drops the connection is retried without validating in between" "status=$STATUS calls=$CALLS"; fi

run_case 0 9
if [ "$STATUS" -ne 0 ] && [ "$(grep -c validate "$TMP/calls")" -eq 4 ]; then pass "the release gives up after STAPLE_ATTEMPTS attempts"; else fail "the release gives up after STAPLE_ATTEMPTS attempts" "status=$STATUS calls=$CALLS"; fi

if [ "$FAILURES" -eq 0 ]; then echo "all staple tests passed"; else echo "$FAILURES staple test(s) failed"; exit 1; fi
