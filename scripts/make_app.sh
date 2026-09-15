#!/bin/sh
# Package dist/BerryDB.app from the SwiftPM binary.
# Version/build and the Sparkle feed come from the environment so the release
# pipeline (deploy/release.sh) can stamp them; signing + notarization happen in
# deploy/release.sh.
set -eu

CONFIG="${1:-release}"
BIN=".build/${CONFIG}/BerryApp"
APP="dist/BerryDB.app"

# Release identity — overridable from .env / the environment.
VERSION="${BERRYDB_VERSION:-0.1.0}"
BUILD="${BERRYDB_BUILD:-1}"
# Sparkle appcast feed. The public EdDSA key is
# embedded only when set, so dev/unsigned bundles don't advertise a feed.
SU_FEED_URL="${SU_FEED_URL:-https://download-db.berryhub.app/appcast.xml}"
SU_PUBLIC_ED_KEY="${SU_PUBLIC_ED_KEY:-}"

[ -x "$BIN" ] || { echo "Not built yet: run 'swift build -c ${CONFIG}' first" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/BerryDB"

BIN_DIR="$(dirname "$BIN")"

# install_name_tool leaves a fresh ad-hoc signature behind after saving (an
# arm64 Mach-O needs SOME signature to be loadable at all), so stripping a
# file's signature once isn't enough if it gets touched more than once —
# libsybdb/libssl each get an -id plus one or more -change calls below, and
# without re-stripping before every single one, only the FIRST call on a
# given file stays quiet; every call after it re-triggers "changes being
# made to the file will invalidate the code signature". Harmless either way
# — the whole app gets a real signature at the end of this script (dev) or
# in deploy/release.sh (release) regardless — but noisy, hence this
# before-every-call wrapper instead of a single strip per file.
quiet_install_name_tool() {
    # Do NOT strip the signature first. Measured on the CI runner against
    # Homebrew's arm64_sequoia FreeTDS bottle: untouched, install_name_tool
    # succeeds; after codesign --remove-signature it fails with "link edit
    # information does not fill the __LINKEDIT segment"; after an ad-hoc
    # re-sign it succeeds again. __LINKEDIT is internally consistent in all
    # three, so that message names the wrong thing. The arm64_tahoe bottle of
    # the same FreeTDS version does not reproduce it, which is why this only
    # ever failed in CI.
    #
    # Stripping only ever bought a quieter log, since the finished app is
    # signed at the end of this script or by the release pipeline regardless.
    # So keep the file intact and drop the expected warning from stderr
    # instead, preserving install_name_tool's exit status.
    # `|| true` on the filter: when the only output was the expected warning,
    # grep matches nothing and exits 1, which under `set -e` would kill the
    # script that is merely trying to keep its log tidy.
    err="$(install_name_tool "$@" 2>&1 >/dev/null)"
    if [ -n "$err" ]; then
        printf '%s\n' "$err" | grep -v 'invalidate the code signature' >&2 || true
    fi
}

# ---- Embed non-system dylib deps (FreeTDS/SQL Server) -------------------------
# The FreeTDS DB-Library driver (LGPL — dynamically linked) pulls in libsybdb +
# OpenSSL from Homebrew via absolute /opt/homebrew paths. Those don't exist on an
# end user's Mac, and even if they did, hardened runtime's library validation
# (on by default without entitlement exceptions) refuses to load a dylib not
# signed by our Developer ID. Embed a real copy into Contents/Frameworks and
# repoint references at @rpath — release.sh's own `codesign --deep` on the finished
# app re-signs everything found there with our identity, satisfying library validation.
# Note: deliberately using `for x in $(cmd)` below, not `cmd | while read`.
# A pipe puts the loop body in a subshell, and EMBEDDED_FREETDS/
# EMBEDDED_OPENSSL are set from inside embed_nonsystem_dep — including when
# it recurses into a NESTED dep (libsybdb -> libssl/libcrypto), several
# calls deep. A subshelled loop would silently lose those assignments the
# moment control returns to the parent shell. Paths here never contain
# spaces (Homebrew Cellar layout), so plain word-splitting is safe.
embed_nonsystem_dep() {
    # `local` on every one of these — this function recurses (libsybdb ->
    # libssl -> libcrypto), and without `local` a nested call clobbers the
    # caller's own dep_dest/dep_name mid-loop: caught by testing this script
    # for real (libsybdb's own reference to libssl never got repointed —
    # the recursive call had already overwritten dep_dest to libssl's/
    # libcrypto's path by the time the outer frame's install_name_tool ran).
    local dep_path="$1"
    local dep_name dep_dest nested_deps nested
    dep_name="$(basename "$dep_path")"
    dep_dest="$APP/Contents/Frameworks/$dep_name"
    if [ -f "$dep_dest" ]; then return; fi   # already embedded (shared dep, e.g. libcrypto)
    cp "$dep_path" "$dep_dest"
    chmod u+w "$dep_dest"
    quiet_install_name_tool -id "@rpath/$dep_name" "$dep_dest"
    case "$dep_name" in libsybdb*) EMBEDDED_FREETDS=1 ;; esac
    case "$dep_name" in libssl*|libcrypto*) EMBEDDED_OPENSSL=1 ;; esac
    # Recurse into this dylib's own non-system deps, then fix up ITS references.
    nested_deps="$(otool -L "$dep_dest" | tail -n +2 | awk '{print $1}')"
    for nested in $nested_deps; do
        case "$nested" in
            /opt/homebrew/*|/usr/local/*)
                embed_nonsystem_dep "$nested"
                quiet_install_name_tool -change "$nested" "@rpath/$(basename "$nested")" "$dep_dest"
                ;;
        esac
    done
}

EMBEDDED_FREETDS=0
EMBEDDED_OPENSSL=0
top_level_deps="$(otool -L "$APP/Contents/MacOS/BerryDB" | tail -n +2 | awk '{print $1}')"
for dep in $top_level_deps; do
    case "$dep" in
        /opt/homebrew/*|/usr/local/*)
            embed_nonsystem_dep "$dep"
            quiet_install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$APP/Contents/MacOS/BerryDB"
            ;;
    esac
done

# LGPL/attribution NOTICE for whatever got embedded above — only when it
# actually applies to this build (a version without FreeTDS linked ships
# none). Deliberately NOT Homebrew's own freetds COPYING.txt — that file is
# GPLv2, which covers FreeTDS's bundled command-line tools (tsql, bsqldb,
# ...), not the libsybdb/DB-Library we actually link. The library itself is
# LGPL 2.1 (confirmed against FreeTDS's own project docs,
#) — vendored verbatim from gnu.org in deploy/third-party-notices/ so
# packaging doesn't depend on Homebrew shipping the right file, or on
# network access at build time.
if [ "$EMBEDDED_FREETDS" = 1 ]; then
    cp deploy/third-party-notices/NOTICE-FreeTDS.txt "$APP/Contents/Resources/NOTICE-FreeTDS.txt"
    cp deploy/third-party-notices/LGPL-2.1.txt "$APP/Contents/Resources/LGPL-2.1.txt"
    # LGPL 6(a)/6(d) oblige us to offer the source of the exact library version
    # shipped, so the notice has to name it. Read it out of the binary that is
    # actually in the bundle rather than asking Homebrew, which may have since
    # moved on or have several versions installed.
    FREETDS_VERSION="$(strings "$APP/Contents/Frameworks/libsybdb.5.dylib" 2>/dev/null \
        | grep -oE 'freetds v[0-9]+\.[0-9]+\.[0-9]+' | sed 's/freetds v//' | sort -u | head -1)"
    [ -n "$FREETDS_VERSION" ] || FREETDS_VERSION="unknown"
    {
        echo ""
        echo "VERSION SHIPPED WITH THIS BUILD: FreeTDS $FREETDS_VERSION"
        echo "Source: https://www.freetds.org/files/stable/freetds-$FREETDS_VERSION.tar.bz2"
        echo "A copy is published alongside each BerryDB release."
    } >> "$APP/Contents/Resources/NOTICE-FreeTDS.txt"
    echo "note: embedded FreeTDS $FREETDS_VERSION" >&2
fi
if [ "$EMBEDDED_OPENSSL" = 1 ]; then
    OPENSSL_NOTICE="$(find /opt/homebrew/Cellar/openssl@3 -maxdepth 2 -iname "LICENSE*" 2>/dev/null | head -1)"
    [ -n "$OPENSSL_NOTICE" ] && cp "$OPENSSL_NOTICE" "$APP/Contents/Resources/NOTICE-OpenSSL.txt"
fi

# SPM resource bundles (localization etc.) must ship inside the app —
# Bundle.module falls back to the main bundle's Resources dir.
for bundle in "$BIN_DIR"/*.bundle ".build/${CONFIG}"/*.bundle; do
    [ -d "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/" 2>/dev/null || true
done

# Dynamic frameworks (e.g. Sparkle.framework) must ship inside Contents/Frameworks/
for fw in "$BIN_DIR"/*.framework ".build/${CONFIG}"/*.framework; do
    [ -d "$fw" ] && cp -R "$fw" "$APP/Contents/Frameworks/" 2>/dev/null || true
done

# App icon (optional). Prefer a prebuilt deploy/AppIcon.icns; otherwise render
# one from deploy/icon-1024.png via iconutil, so a release only needs the 1024px
# art dropped in. No icon → the default system icon (fine for dev builds).
ICON_KEY=""
ICNS="deploy/AppIcon.icns"
ICON_PNG="deploy/icon-1024.png"
if [ ! -f "$ICNS" ] && [ -f "$ICON_PNG" ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    gen() { sips -z "$2" "$2" "$ICON_PNG" --out "$ICONSET/$1" >/dev/null; }
    gen icon_16x16.png 16;      gen icon_16x16@2x.png 32
    gen icon_32x32.png 32;      gen icon_32x32@2x.png 64
    gen icon_128x128.png 128;   gen icon_128x128@2x.png 256
    gen icon_256x256.png 256;   gen icon_256x256@2x.png 512
    gen icon_512x512.png 512;   gen icon_512x512@2x.png 1024
    iconutil -c icns "$ICONSET" -o "$ICNS"
fi
if [ -f "$ICNS" ]; then
    cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
    ICON_KEY="    <key>CFBundleIconFile</key><string>AppIcon</string>"
else
    echo "note: no app icon (add deploy/AppIcon.icns or deploy/icon-1024.png)" >&2
fi

# Sparkle keys only when a public key is provided (a real release build).
SPARKLE_KEYS=""
if [ -n "$SU_PUBLIC_ED_KEY" ]; then
    SPARKLE_KEYS="    <key>SUFeedURL</key><string>${SU_FEED_URL}</string>
    <key>SUPublicEDKey</key><string>${SU_PUBLIC_ED_KEY}</string>
    <key>SUEnableInstallerLauncherService</key><true/>"
fi

# Load local dev env if available (.env.prod as a base, .env wins for
# anything it sets). Deploy secrets in deploy/.env are sourced by release.sh
# before invoking this script.
# Preserve any environment variables already exported by release.sh
# (e.g. production BERRYDB_BACKEND_URL or BERRYDB_LICENSE_PUBLIC_KEY) so that
# a developer's local .env does not overwrite production release settings.
_release_backend_url="${BERRYDB_BACKEND_URL:-}"
_release_license_key="${BERRYDB_LICENSE_PUBLIC_KEY:-}"
[ -f .env.prod ] && set -a && . ./.env.prod && set +a
[ -f .env ] && set -a && . ./.env && set +a
[ -n "$_release_backend_url" ] && BERRYDB_BACKEND_URL="$_release_backend_url"
[ -n "$_release_license_key" ] && BERRYDB_LICENSE_PUBLIC_KEY="$_release_license_key"

BACKEND_URL_KEY=""
if [ -n "${BERRYDB_BACKEND_URL:-}" ]; then
    BACKEND_URL_KEY="    <key>BERRYDB_BACKEND_URL</key><string>${BERRYDB_BACKEND_URL}</string>"
fi

# License signature-verification key (LicenseSupport.publicKeyBase64()) —
# a Finder-launched .app never inherits the shell env a dev sets in
# .env/deploy/.env, so this MUST be embedded into Info.plist (like
# BERRYDB_BACKEND_URL above) for a real release build, or the app silently
# verifies against the built-in dev key instead of production's real one
# and every activation/trial/top-up fails signature verification.
LICENSE_KEY_KEY=""
if [ -n "${BERRYDB_LICENSE_PUBLIC_KEY:-}" ]; then
    LICENSE_KEY_KEY="    <key>BERRYDB_LICENSE_PUBLIC_KEY</key><string>${BERRYDB_LICENSE_PUBLIC_KEY}</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array>
        <string>en</string>
        <string>vi</string>
    </array>
    <key>CFBundleExecutable</key><string>BerryDB</string>
    <key>CFBundleIdentifier</key><string>dev.berrydb.app</string>
    <key>CFBundleName</key><string>BerryDB</string>
    <key>CFBundleDisplayName</key><string>BerryDB</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>SQL Script</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.sql</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>sql</string>
            </array>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>public.sql</string>
            <key>UTTypeDescription</key>
            <string>SQL Script</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.plain-text</string>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>sql</string>
                    <string>SQL</string>
                </array>
            </dict>
        </dict>
    </array>
${ICON_KEY}
${SPARKLE_KEYS}
${BACKEND_URL_KEY}
${LICENSE_KEY_KEY}
</dict>
</plist>
PLIST

# Ensure @loader_path/../Frameworks is in the executable's LC_RPATH so dyld locates embedded frameworks
quiet_install_name_tool -add_rpath "@loader_path/../Frameworks" "$APP/Contents/MacOS/BerryDB" 2>/dev/null || true

# Re-sign the app bundle ad-hoc so code signature remains valid for local dev
codesign --force --deep -s - "$APP" 2>/dev/null || true

# Register with LaunchServices so Finder recognizes the file association immediately
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true

echo "OK: $APP (v${VERSION} build ${BUILD})"
