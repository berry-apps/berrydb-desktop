#!/bin/sh
# Tests for scripts/sign-update.sh. Runs in about a second: every case uses a stub
# sign_update, so nothing here signs, builds or reaches the network.
set -eu

SCRIPT="$(cd "$(dirname "$0")" && pwd)/sign-update.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; echo "       $2"; FAILURES=$((FAILURES + 1)); }

DMG="$TMP/BerryDB-1.0.0.dmg"
echo "not really a dmg" > "$DMG"

# A stub standing in for Sparkle's sign_update. Echoes the arguments it was given
# to $TMP/args so the tests can assert how it was invoked, then prints a signature
# the way `sign_update -p` does: the bare signature, no XML around it.
STUB="$TMP/sign_update"
cat > "$STUB" <<'STUB_EOF'
#!/bin/sh
printf '%s\n' "$*" > "$(dirname "$0")/args"
cat > "$(dirname "$0")/stdin" 2>/dev/null || true
echo "SIGNATURE_FROM_STUB"
STUB_EOF
chmod +x "$STUB"

# 1. Signs with an explicit key and prints ONLY the signature.
OUT="$(SPARKLE_BIN="$STUB" SPARKLE_PRIVATE_ED_KEY="testkey123" sh "$SCRIPT" "$DMG")"
[ "$OUT" = "SIGNATURE_FROM_STUB" ] \
  && pass "prints only the signature" \
  || fail "prints only the signature" "got: $OUT"

# 2. The key arrives on stdin, never in the argument list. `-s <key>` was how
#    this used to work; Sparkle 2.9.4 exits 1 and prints nothing for it, and
#    arguments are readable by every process on the machine besides.
ARGS="$(cat "$TMP/args")"
case "$ARGS" in
  *"--ed-key-file -"*) pass "reads the key from stdin via --ed-key-file -" ;;
  *) fail "reads the key from stdin via --ed-key-file -" "args were: $ARGS" ;;
esac
case "$ARGS" in
  *testkey123*) fail "keeps the key out of the argument list" "args were: $ARGS" ;;
  *) pass "keeps the key out of the argument list" ;;
esac
case "$(cat "$TMP/stdin" 2>/dev/null)" in
  *testkey123*) pass "the key actually reaches stdin" ;;
  *) fail "the key actually reaches stdin" "stdin was: $(cat "$TMP/stdin" 2>/dev/null)" ;;
esac
case "$ARGS" in
  *-p*) pass "asks sign_update for print-only output" ;;
  *) fail "asks sign_update for print-only output" "args were: $ARGS" ;;
esac

# 3. With no key set it must NOT pass --ed-key-file, so sign_update falls back
#    to the Keychain. That is the path a local release uses.
SPARKLE_BIN="$STUB" sh "$SCRIPT" "$DMG" >/dev/null </dev/null
ARGS="$(cat "$TMP/args")"
case "$ARGS" in
  *--ed-key-file*) fail "omits --ed-key-file when no key is set" "args were: $ARGS" ;;
  *) pass "omits --ed-key-file when no key is set" ;;
esac

# 4. Signing unavailable, running locally: warn, print nothing, succeed.
#    Releasing an unsigned build by hand while testing is legitimate.
set +e
OUT="$(SPARKLE_BIN="$TMP/does-not-exist" sh "$SCRIPT" "$DMG" 2>"$TMP/err" </dev/null)"
CODE=$?
set -e
[ "$CODE" -eq 0 ] && [ -z "$OUT" ] \
  && pass "unavailable + no CI: exits 0 with empty output" \
  || fail "unavailable + no CI: exits 0 with empty output" "exit=$CODE out=$OUT"
grep -q "UNSIGNED" "$TMP/err" \
  && pass "unavailable + no CI: warns on stderr" \
  || fail "unavailable + no CI: warns on stderr" "stderr: $(cat "$TMP/err")"

# 5. Signing unavailable under CI: fatal. An unsigned appcast entry published by
#    automation is a release users cannot install, discovered only by report.
set +e
CI=1 SPARKLE_BIN="$TMP/does-not-exist" sh "$SCRIPT" "$DMG" >/dev/null 2>"$TMP/err" </dev/null
CODE=$?
set -e
[ "$CODE" -ne 0 ] \
  && pass "unavailable + CI: exits non-zero" \
  || fail "unavailable + CI: exits non-zero" "exit=$CODE"

# 6. A stub that prints nothing must also be fatal under CI — an empty signature is
#    just as unusable as no signing at all.
EMPTY="$TMP/sign_update_empty"
printf '#!/bin/sh\nexit 0\n' > "$EMPTY"
chmod +x "$EMPTY"
set +e
CI=1 SPARKLE_BIN="$EMPTY" SPARKLE_PRIVATE_ED_KEY="k" sh "$SCRIPT" "$DMG" >/dev/null 2>&1 </dev/null
CODE=$?
set -e
[ "$CODE" -ne 0 ] \
  && pass "empty signature + CI: exits non-zero" \
  || fail "empty signature + CI: exits non-zero" "exit=$CODE"

# 7. Against the REAL sign_update. Every case above uses a stub, and a stub
#    accepts whatever it is handed -- which is exactly how `-s <key>` survived
#    here after Sparkle stopped honouring it. Deliberately no Keychain:
#    generate_keys prompts for access, and a prompt in a test is a hang. A
#    bogus key is enough to tell "option removed" from "key rejected".
REAL="$(find .build -name sign_update -type f 2>/dev/null | head -1)"
if [ -n "$REAL" ]; then
  set +e
  printf 'not-a-real-key\n' | "$REAL" --ed-key-file - -p "$DMG" >/dev/null 2>"$TMP/real"
  set -e
  if grep -qiE 'unknown option|unexpected argument|invalid option' "$TMP/real"; then
    fail "real sign_update still accepts --ed-key-file" "$(head -c 160 "$TMP/real")"
  else
    pass "real sign_update still accepts --ed-key-file"
  fi
  set +e
  printf 'not-a-real-key\n' | "$REAL" -s dummy -p "$DMG" >/dev/null 2>"$TMP/real2"
  set -e
  if grep -qi 'deprecated' "$TMP/real2"; then
    pass "real sign_update confirms -s is deprecated (why we moved off it)"
  else
    echo "note - -s no longer warns; the reason for --ed-key-file may have changed"
  fi
else
  echo "skip - real sign_update unavailable (build first to cover this)"
fi


echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All sign-update tests passed."
else
  echo "$FAILURES test(s) failed."
  exit 1
fi
