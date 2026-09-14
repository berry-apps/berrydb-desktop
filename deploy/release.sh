#!/bin/bash
# BerryDB release: build → package → codesign (hardened runtime) → notarize →
# staple → zip → Sparkle-sign. Produces dist/BerryDB-<version>.zip and
# deploy/last-release.json (consumed by upload-release.py).
# (hardening) + (distribution).
#
# Secrets come from deploy/.env (gitignored) — never hardcode. Nothing here
# uploads; run deploy/upload-release.py after this to publish.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ---- Config (env / deploy/.env) ---------------------------------------------
[ -f deploy/.env ] && set -a && . ./deploy/.env && set +a

VERSION="${1:-${BERRYDB_VERSION:-0.1.0}}"
BUILD="${BERRYDB_BUILD:-$(date +%Y%m%d%H%M)}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
ENTITLEMENTS="deploy/BerryDB.entitlements"
APP="dist/BerryDB.app"
ZIP="dist/BerryDB-${VERSION}.zip"
# Sparkle's sign_update — from a Sparkle checkout / release. Override if needed.
SPARKLE_BIN="${SPARKLE_BIN:-}"

need() { [ -n "${!1:-}" ] || { echo "✗ Missing required env: $1 (set it in .env)" >&2; exit 1; }; }
need APPLE_ID
need APP_SPEC_PASSWORD
need SIGNING_IDENTITY
need APPLE_TEAM_ID
# BerryDB must ship with its own feed and public EdDSA key for Sparkle updates.
need SU_FEED_URL
need SU_PUBLIC_ED_KEY

echo "▸ Building release binary…"
swift build -c release

echo "▸ Packaging ${APP} (v${VERSION})…"
BERRYDB_VERSION="$VERSION" BERRYDB_BUILD="$BUILD" \
  SU_FEED_URL="$SU_FEED_URL" \
  SU_PUBLIC_ED_KEY="$SU_PUBLIC_ED_KEY" \
  scripts/make_app.sh release

# Embed + sign Sparkle from the inside out (deploy/README.md): XPC services,
# then the framework; the outer --deep sign below re-signs everything with our
# Developer ID so library validation passes.
FW="$(swift build -c release --show-bin-path)/Sparkle.framework"
if [ -d "$FW" ]; then
  echo "▸ Embedding Sparkle.framework…"
  mkdir -p "$APP/Contents/Frameworks"
  rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
  ditto "$FW" "$APP/Contents/Frameworks/Sparkle.framework"
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
    "$APP"/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/*.xpc
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
    "$APP/Contents/Frameworks/Sparkle.framework"
else
  echo "⚠ Sparkle.framework not found in release bin path — updater will be a no-op." >&2
fi

echo "▸ Codesigning (hardened runtime, deep)…"
# Sign nested code first (frameworks/dylibs), then the app — deep + runtime.
codesign --force --deep --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "▸ Zipping app for notarization…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "▸ Submitting app to Apple notary service (this can take a few minutes)…"
xcrun notarytool submit "$ZIP" \
  --apple-id "$APPLE_ID" \
  --password "$APP_SPEC_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" \
  --wait

echo "▸ Stapling the app (offline-safe once dragged out of the DMG)…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$ZIP"   # the zip was only the notarization vehicle

# ---- Build the drag-to-Applications DMG (the download users get) ------------
DMG="dist/BerryDB-${VERSION}.dmg"
STAGING="dist/dmg_staging"
echo "▸ Building DMG…"
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"   # drag target
rm -f "$DMG"
hdiutil create -volname "BerryDB" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"

echo "▸ Notarizing the DMG…"
xcrun notarytool submit "$DMG" \
  --apple-id "$APPLE_ID" \
  --password "$APP_SPEC_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" \
  --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# ---- Sparkle EdDSA signature (Sparkle 2 installs from a .dmg) ---------------
ED_SIG=""
LENGTH="$(stat -f%z "$DMG")"
echo "▸ Signing update with Sparkle EdDSA key…"
ED_SIG="$(scripts/sign-update.sh "$DMG")"

# ---- Release manifest for the upload step -----------------------------------
cat > deploy/last-release.json <<JSON
{
  "version": "${VERSION}",
  "build": "${BUILD}",
  "file": "BerryDB-${VERSION}.dmg",
  "path": "${DMG}",
  "length": ${LENGTH},
  "edSignature": "${ED_SIG}",
  "minimumSystemVersion": "14.0",
  "pubDate": "$(date -u +'%a, %d %b %Y %H:%M:%S +0000')"
}
JSON

echo "✓ Release ready: ${DMG}"
echo "  Next: python3 deploy/upload-release.py   (uploads + updates the appcast)"
