#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# BerryDB WebApp Production Deployment Script
# Supports: Version Extraction, Nginx Config Deployment, Atomic Blue/Green Switch
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEBAPP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$WEBAPP_DIR/.." && pwd)"
RELEASES_JSON="$ROOT_DIR/deploy/last-release.json"

DEPLOY_PATH="${DEPLOY_PATH:-/var/www/berrydb}"
NGINX_CONF_SRC="$WEBAPP_DIR/deploy/nginx.conf"
NGINX_CONF_DST="${NGINX_CONF_DST:-/etc/nginx/sites-available/db.berryhub.app}"
NGINX_CONF_LINK="${NGINX_CONF_LINK:-/etc/nginx/sites-enabled/db.berryhub.app}"
SUDO_CMD="${SUDO_CMD:-sudo}"

echo "🫐 [BerryDB] Starting WebApp Deployment..."

# ── 1. Resolve Version ────────────────────────────────────────────────────────
# In order of authority, stopping at the first that answers:
#   1. BERRYDB_VERSION  - the release pipeline just published this version and
#                         says so explicitly. Always right when present.
#   2. deploy/last-release.json - a local release left this behind. Untracked,
#                         so it is absent on a fresh CI checkout.
#   3. the live version.json - nobody told us a version (a push that only
#                         touched webapp/), so keep publishing the one already
#                         deployed rather than inventing one.
# There used to be a `VERSION="1.0.2"` here as step 0. It was not a default: it
# was a wrong answer, given confidently, that outlived three releases and
# silently overwrote every version the pipeline passed in.
VERSION="${BERRYDB_VERSION:-}"
[ -n "$VERSION" ] && echo "📦 Version from the release pipeline: v$VERSION"

if [ -z "$VERSION" ] && [ -f "$RELEASES_JSON" ]; then
    VERSION=$(grep -oE '"version": "[^"]+"' "$RELEASES_JSON" | head -n 1 | awk -F'"' '{print $4}' || true)
    [ -n "$VERSION" ] && echo "📦 Version from $RELEASES_JSON: v$VERSION"
fi

LIVE_VERSION_JSON="$DEPLOY_PATH/current/version.json"
if [ -z "$VERSION" ] && [ -f "$LIVE_VERSION_JSON" ]; then
    VERSION=$(grep -oE '"version": "[^"]+"' "$LIVE_VERSION_JSON" | head -n 1 | awk -F'"' '{print $4}' || true)
    [ -n "$VERSION" ] && echo "ℹ️  No version supplied; keeping the deployed v$VERSION"
fi

if [ -z "$VERSION" ]; then
    echo "✗ No version to publish: BERRYDB_VERSION is unset, $RELEASES_JSON is" >&2
    echo "  absent, and nothing is deployed at $LIVE_VERSION_JSON yet." >&2
    echo "  Re-run with BERRYDB_VERSION=x.y.z, or dispatch the workflow with" >&2
    echo "  force_version set." >&2
    exit 1
fi
echo "📦 Deploying BerryDB Version: v$VERSION"

# ── 2. Update Version in HTML & Generate version.json ─────────────────────────
RELEASE_DATE="$(date -u +"%Y-%m-%d")"
# The commit of the WEBSITE deploy, not of the app build. A webapp-only deploy
# runs long after the release that produced the DMG, so naming this "commit"
# next to "version" read as "1.0.3 was built from this SHA", which was false.
COMMIT_SHA="${GITHUB_SHA:-$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "latest")}"

# Create/Update version.json
mkdir -p "$WEBAPP_DIR/public"
cat <<EOF > "$WEBAPP_DIR/public/version.json"
{
  "name": "BerryDB",
  "version": "$VERSION",
  "releaseDate": "$RELEASE_DATE",
  "webCommit": "$COMMIT_SHA",
  "downloadUrl": "https://download-db.berryhub.app/BerryDB-latest.dmg",
  "downloadDmgUrl": "https://download-db.berryhub.app/BerryDB-latest.dmg",
  "minMacOS": "15.0",
  "architecture": "Apple Silicon (arm64)"
}
EOF
cp "$WEBAPP_DIR/public/version.json" "$WEBAPP_DIR/version.json"
echo "✅ Generated version.json (v$VERSION)"

# Rewrite every version badge in the pages.
#
# The pattern is deliberately "v" followed by all three semver components. It
# used to be "BerryDB v<ver>", which matched the announcement ribbon and missed
# the two download buttons -- they carry a bare "v1.0.2" -- so the site shipped
# 1.0.3 in the ribbon and 1.0.2 on the button people actually click.
#
# Three components are required because these pages carry SVG path data full of
# numbers like "1.36.08", and "v" is also an SVG path command. Requiring the "v"
# prefix AND three components matches the badges and nothing else; test-deploy-
# version.sh asserts that against the real pages on every deploy.
#
# No \b: BSD sed (macOS, where this test is usually run) does not implement word
# boundaries and silently matches nothing, so the rewrite would quietly do nothing
# there while working on the GNU-sed deploy host.
for page in index.html docs.html; do
    [ -f "$WEBAPP_DIR/$page" ] || continue
    sed -i.bak -E "s/v[0-9]+\.[0-9]+\.[0-9]+/v$VERSION/g" "$WEBAPP_DIR/$page"
    rm -f "$WEBAPP_DIR/$page.bak"
    echo "✅ Synchronized version in $page"
done

# ── 3. Deploy & Validate Nginx Configuration ───────────────────────────────────
if [ -f "$NGINX_CONF_SRC" ]; then
    echo "🔧 Deploying Nginx configuration..."
    if [ -w "/etc/nginx" ] || [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
        $SUDO_CMD mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
        $SUDO_CMD cp "$NGINX_CONF_SRC" "$NGINX_CONF_DST"
        
        if [ ! -L "$NGINX_CONF_LINK" ] && [ ! -f "$NGINX_CONF_LINK" ]; then
            $SUDO_CMD ln -sf "$NGINX_CONF_DST" "$NGINX_CONF_LINK"
            echo "🔗 Created symlink: $NGINX_CONF_LINK"
        fi

        # Validate Nginx
        if command -v nginx >/dev/null 2>&1; then
            $SUDO_CMD nginx -t || true
            echo "✅ Nginx configuration syntax checked."
        fi
    else
        echo "⚠️ Non-elevated environment detected, skipping /etc/nginx writes."
    fi
fi

# ── 4. Atomic Blue/Green Slot Deployment ──────────────────────────────────────
if [ -w "$(dirname "$DEPLOY_PATH")" ] || [ -w "$DEPLOY_PATH" ]; then
    mkdir -p "$DEPLOY_PATH"/{blue,green}
else
    $SUDO_CMD mkdir -p "$DEPLOY_PATH"/{blue,green}
    $SUDO_CMD chown -R "$USER:$USER" "$DEPLOY_PATH" 2>/dev/null || true
fi

# Determine inactive slot
NEXT_SLOT="blue"
if [ -L "$DEPLOY_PATH/current" ]; then
    CURRENT_TARGET=$(readlink "$DEPLOY_PATH/current" || true)
    if echo "$CURRENT_TARGET" | grep -q "/blue"; then
        NEXT_SLOT="green"
    else
        NEXT_SLOT="blue"
    fi
fi

TARGET_DIR="$DEPLOY_PATH/$NEXT_SLOT"
echo "🚀 Syncing webapp static files to slot: $NEXT_SLOT ($TARGET_DIR)..."
mkdir -p "$TARGET_DIR"

# Rsync webapp files
rsync -avz --delete \
    --exclude="deploy" \
    --exclude=".git" \
    --exclude="*.bak" \
    "$WEBAPP_DIR/" "$TARGET_DIR/"

# Smoke test slot
if [ ! -f "$TARGET_DIR/index.html" ]; then
    echo "❌ Deployment error: index.html not found in $TARGET_DIR!"
    exit 1
fi

# Atomic Symlink Swap
ln -sfn "$TARGET_DIR" "$DEPLOY_PATH/current"
echo "🔁 Swapped current -> $NEXT_SLOT"

# ── 5. Reload Nginx ───────────────────────────────────────────────────────────
if command -v nginx >/dev/null 2>&1; then
    if command -v systemctl >/dev/null 2>&1; then
        $SUDO_CMD systemctl reload nginx || $SUDO_CMD nginx -s reload 2>/dev/null || true
    else
        $SUDO_CMD nginx -s reload 2>/dev/null || true
    fi
    echo "🎉 Nginx reloaded successfully!"
fi

echo "✨ BerryDB WebApp v$VERSION is now LIVE at https://db.berryhub.app"
