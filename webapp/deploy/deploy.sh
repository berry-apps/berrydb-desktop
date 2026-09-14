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

# ── 1. Extract Version ────────────────────────────────────────────────────────
VERSION="1.0.2"
if [ -f "$RELEASES_JSON" ]; then
    EXTRACTED=$(grep -oE '"version": "[0-9]+\.[0-9]+\.[0-9]+"' "$RELEASES_JSON" | head -n 1 | awk -F'"' '{print $4}' || true)
    if [ -n "$EXTRACTED" ]; then
        VERSION="$EXTRACTED"
    fi
fi
echo "📦 Detected BerryDB Version: v$VERSION"

# ── 2. Update Version in HTML & Generate version.json ─────────────────────────
RELEASE_DATE="$(date -u +"%Y-%m-%d")"
COMMIT_SHA="${GITHUB_SHA:-$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "latest")}"

# Create/Update version.json
mkdir -p "$WEBAPP_DIR/public"
cat <<EOF > "$WEBAPP_DIR/public/version.json"
{
  "name": "BerryDB",
  "version": "$VERSION",
  "releaseDate": "$RELEASE_DATE",
  "commit": "$COMMIT_SHA",
  "downloadUrl": "https://download-db.berryhub.app/BerryDB-latest.dmg",
  "downloadDmgUrl": "https://download-db.berryhub.app/BerryDB-latest.dmg",
  "minMacOS": "14.0",
  "architecture": "Apple Silicon (arm64)"
}
EOF
cp "$WEBAPP_DIR/public/version.json" "$WEBAPP_DIR/version.json"
echo "✅ Generated version.json (v$VERSION)"

# Replace version announcement badge in index.html & docs.html if placeholder exists
if [ -f "$WEBAPP_DIR/index.html" ]; then
    sed -i.bak -E "s/BerryDB v[0-9]+\.[0-9]+(\.[0-9]+)?/BerryDB v$VERSION/g" "$WEBAPP_DIR/index.html" && rm -f "$WEBAPP_DIR/index.html.bak"
    echo "✅ Synchronized version in index.html"
fi

if [ -f "$WEBAPP_DIR/docs.html" ]; then
    sed -i.bak -E "s/BerryDB v[0-9]+\.[0-9]+(\.[0-9]+)?/BerryDB v$VERSION/g" "$WEBAPP_DIR/docs.html" && rm -f "$WEBAPP_DIR/docs.html.bak"
    echo "✅ Synchronized version in docs.html"
fi

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
