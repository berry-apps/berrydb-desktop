#!/bin/sh
# Mount a release DMG read-only and copy the .app bundle out of it.
#
# BinaryDelta diffs two .app bundles, not two .dmg files (see build-delta.sh and
# deploy/upload-release.py's generate_deltas()). Once a release's CI runner is
# gone, the DMG on R2 is the only place that version's already-signed,
# notarized, stapled .app still exists, so reconstructing the "old" side of a
# delta means mounting that DMG and copying the bundle back out -- never
# rebuilding or re-signing it, which would produce different bytes than what
# users actually have installed and make the delta useless.
set -eu

DMG="${1:?usage: extract-app-from-dmg.sh <dmg-path> <dest-app-path>}"
DEST="${2:?usage: extract-app-from-dmg.sh <dmg-path> <dest-app-path>}"

[ -f "$DMG" ] || { echo "extract-app-from-dmg: no such file: $DMG" >&2; exit 1; }

MOUNT_POINT="$(mktemp -d)"
cleanup() {
    hdiutil detach "$MOUNT_POINT" -quiet -force >/dev/null 2>&1 || true
    rmdir "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT

hdiutil attach "$DMG" -mountpoint "$MOUNT_POINT" -nobrowse -readonly -noautoopen -quiet

APP="$(find "$MOUNT_POINT" -maxdepth 1 -name '*.app' -print -quit)"
[ -n "$APP" ] || { echo "extract-app-from-dmg: no .app bundle found in $DMG" >&2; exit 1; }

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
ditto "$APP" "$DEST"
