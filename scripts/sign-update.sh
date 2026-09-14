#!/bin/sh
# Print the Sparkle EdDSA signature for a release artifact, and nothing else.
#
# Extracted from release.sh so the "cannot sign" path can be tested without
# running a build and two notarization round-trips. See
# scripts/test-sign-update.sh.
#
# The key comes from one of two places. Locally it stays in the login Keychain,
# where `generate_keys` put it, and sign_update finds it by itself. On a CI runner
# there is no such Keychain, so SPARKLE_PRIVATE_ED_KEY carries it instead.
set -eu

DMG="${1:?usage: sign-update.sh <path-to-dmg>}"

if [ -z "${SPARKLE_BIN:-}" ]; then
    SPARKLE_BIN="$(find .build -name sign_update -type f 2>/dev/null | head -1 || true)"
fi

if [ -n "${SPARKLE_BIN:-}" ] && [ -x "$SPARKLE_BIN" ]; then
    # -p prints the bare signature instead of a full appcast enclosure attribute.
    if [ -n "${SPARKLE_PRIVATE_ED_KEY:-}" ]; then
        # The key goes in on stdin, which is what Sparkle documents:
        #   echo "$PRIVATE_KEY_SECRET" | ./sign_update --ed-key-file -
        # The older `-s <key>` is not merely deprecated, it now exits 1 and
        # prints nothing (checked against Sparkle 2.9.4). Passing it this way
        # also keeps the key out of the argument list, which every process on
        # the machine can read.
        SIG="$(printf '%s\n' "$SPARKLE_PRIVATE_ED_KEY" | "$SPARKLE_BIN" --ed-key-file - -p "$DMG")"
    else
        SIG="$("$SPARKLE_BIN" -p "$DMG")"
    fi
    if [ -z "$SIG" ] && [ -n "${CI:-}" ]; then
        echo "sign_update produced an empty signature. Refusing to publish an unsigned update." >&2
        exit 1
    fi
    printf '%s' "$SIG"
    exit 0
fi

# Under automation this must be fatal. An unsigned appcast entry is a release the
# updater will refuse, and nobody reads a warning in a log that scrolled past —
# it surfaces weeks later as "updates stopped working". By hand it stays a
# warning, because producing an unsigned build while testing is legitimate.
if [ -n "${CI:-}" ]; then
    echo "sign_update not found and CI is set. Refusing to publish an unsigned update." >&2
    exit 1
fi
echo "sign_update not found — appcast entry will be UNSIGNED. Set SPARKLE_BIN." >&2
exit 0
