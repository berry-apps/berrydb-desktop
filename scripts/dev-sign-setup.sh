#!/usr/bin/env bash
# One-time setup: create a STABLE self-signed code-signing identity for local
# dev builds. Because `swift build` produces a differently-hashed binary each
# time, macOS Keychain sees every rebuild as a new app and re-prompts for the
# saved DB password on connect. Signing every dev build with the same identity
# gives Keychain a stable owner, so a single "Always Allow" sticks across
# rebuilds.
#
# This only touches your LOGIN keychain and is dev-only — production release
# signing is separate (Developer ID, see deploy/README.md). Run once:
#
#   scripts/dev-sign-setup.sh
#
# After this, `make run` / scripts/run.sh sign automatically. The very first
# connect still prompts twice — "codesign wants to sign" and BerryDB wanting the
# DB password — click "Always Allow" on both; later rebuilds stay quiet.
set -euo pipefail

IDENTITY="BerryDB Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "✓ Identity \"$IDENTITY\" already exists — nothing to do."
    exit 0
fi

echo "▸ Creating self-signed code-signing identity \"$IDENTITY\"…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/ext.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = BerryDB Dev
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/ext.cnf" >/dev/null 2>&1

# -legacy + -macalg sha1: OpenSSL 3.x defaults to AES-256 encryption and a
# SHA-256 MAC for PKCS12 export, neither of which macOS's `security import`
# can verify ("MAC verification failed during PKCS12 import") — confirmed
# directly (not assumed): -legacy alone still failed, only adding -macalg
# sha1 on top of it actually imports. A genuinely empty PKCS12 password
# *also* fails the same way regardless of algorithm (confirmed separately) —
# not a real secret (immediately imported and discarded via the `trap` above),
# just a fixed placeholder to satisfy the container format.
P12_PASSWORD="berrydb-dev-local-only"
openssl pkcs12 -export -legacy -macalg sha1 -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout "pass:$P12_PASSWORD" -name "$IDENTITY" >/dev/null 2>&1

# Import into the login keychain and pre-authorize codesign to use the key.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign

echo "✓ Done. Now run 'make run' — dev builds sign as \"$IDENTITY\"."
echo "  On the first connect, click \"Always Allow\" on both prompts."
