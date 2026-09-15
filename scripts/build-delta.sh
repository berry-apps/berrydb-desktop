#!/bin/sh
# Run Sparkle's BinaryDelta tool to create a patch between two .app bundles.
#
# Extracted so deploy/upload-release.py has one thing to shell out to instead of
# hardcoding where BinaryDelta lives; the lookup mirrors how sign-update.sh finds
# sign_update (both ship from the same SwiftPM Sparkle checkout under .build).
# Signing the resulting patch is deliberately NOT done here -- that reuses
# scripts/sign-update.sh directly, so there stays exactly one place in this repo
# that knows how to invoke sign_update.
#
# Exit codes matter to the caller: 2 means "BinaryDelta isn't available at all",
# which deploy/upload-release.py treats as "stop trying every candidate, not just
# this one" (see generate_deltas's _BinaryDeltaUnavailable). Any other non-zero
# exit is a per-pair failure the caller skips and moves on from.
set -eu

OLD_APP="${1:?usage: build-delta.sh <old-app> <new-app> <output-delta>}"
NEW_APP="${2:?usage: build-delta.sh <old-app> <new-app> <output-delta>}"
OUT="${3:?usage: build-delta.sh <old-app> <new-app> <output-delta>}"

if [ -z "${BINARY_DELTA_BIN:-}" ]; then
    BINARY_DELTA_BIN="$(find .build -name BinaryDelta -type f 2>/dev/null | head -1 || true)"
fi

if [ -z "${BINARY_DELTA_BIN:-}" ] || [ ! -x "$BINARY_DELTA_BIN" ]; then
    echo "build-delta: BinaryDelta tool not found (set BINARY_DELTA_BIN)" >&2
    exit 2
fi

[ -d "$OLD_APP" ] || { echo "build-delta: old app is not a directory: $OLD_APP" >&2; exit 1; }
[ -d "$NEW_APP" ] || { echo "build-delta: new app is not a directory: $NEW_APP" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
"$BINARY_DELTA_BIN" create "$OLD_APP" "$NEW_APP" "$OUT"
