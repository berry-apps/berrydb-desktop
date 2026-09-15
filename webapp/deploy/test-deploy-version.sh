#!/usr/bin/env bash
# Tests the version deploy.sh publishes, by running the real deploy.sh against a
# throwaway webapp tree and a throwaway DEPLOY_PATH.
#
# This exists because a hardcoded VERSION="1.0.2" sat in deploy.sh for three
# releases: the pipeline passed the right version in, the script ignored it, and
# the website advertised a version that was two releases old while the download
# link served the new one. Nothing failed — it just published the wrong number.
#
# Usage:  webapp/deploy/test-deploy-version.sh [path/to/deploy.sh]
set -uo pipefail

SCRIPT_UNDER_TEST="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deploy.sh}"
[ -f "$SCRIPT_UNDER_TEST" ] || { echo "no such script: $SCRIPT_UNDER_TEST" >&2; exit 1; }
SCRIPT_UNDER_TEST="$(cd "$(dirname "$SCRIPT_UNDER_TEST")" && pwd)/$(basename "$SCRIPT_UNDER_TEST")"

PASS=0; FAIL=0

# A throwaway webapp tree: deploy.sh needs its own directory, the pages it
# rewrites, and somewhere to write version.json.
#
# The REAL index.html and docs.html are copied in, not a stub. A stub only proves
# the script can rewrite the badge the stub happens to contain -- which is how two
# download buttons kept saying v1.0.2 while a stub test passed. Copying the real
# pages means a badge added later, in a spelling nobody anticipated, fails here.
REAL_PAGES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
setup() {
    SANDBOX="$(mktemp -d)"
    mkdir -p "$SANDBOX/root/webapp/deploy" "$SANDBOX/root/deploy" "$SANDBOX/live"
    cp "$SCRIPT_UNDER_TEST" "$SANDBOX/root/webapp/deploy/deploy.sh"
    if [ -f "$REAL_PAGES/index.html" ]; then
        cp "$REAL_PAGES/index.html" "$SANDBOX/root/webapp/index.html"
        [ -f "$REAL_PAGES/docs.html" ] && cp "$REAL_PAGES/docs.html" "$SANDBOX/root/webapp/docs.html"
    else
        echo '<h1>BerryDB v0.0.0</h1>' > "$SANDBOX/root/webapp/index.html"
    fi
}
teardown() { rm -rf "$SANDBOX"; }

# Runs deploy.sh and echoes the version it wrote into version.json, or the exit
# status prefixed with "exit:" when it refused to deploy.
run_deploy() {
    OUT="$(cd "$SANDBOX/root/webapp/deploy" && DEPLOY_PATH="$SANDBOX/live" SUDO_CMD=true \
        bash ./deploy.sh 2>&1)"
    STATUS=$?
    if [ "$STATUS" -ne 0 ]; then echo "exit:$STATUS"; return; fi
    grep -oE '"version": "[^"]+"' "$SANDBOX/root/webapp/public/version.json" \
        | head -1 | awk -F'"' '{print $4}'
}

check() { # name expected actual
    if [ "$2" = "$3" ]; then
        printf '  ok   %s\n' "$1"; PASS=$((PASS + 1))
    else
        printf '  FAIL %s\n       expected %-12s got %s\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1))
        [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | sed 's/^/       | /'
    fi
}

echo "testing $SCRIPT_UNDER_TEST"

# 1. The release pipeline says 1.0.3. Nothing else may override it -- this is the
#    regression: a stale last-release.json and a stale live site both disagree.
setup
echo '{"version": "0.9.1"}' > "$SANDBOX/root/deploy/last-release.json"
mkdir -p "$SANDBOX/live/current"
echo '{"version": "0.9.2"}' > "$SANDBOX/live/current/version.json"
check "BERRYDB_VERSION wins over every stale source" "1.0.3" \
    "$(BERRYDB_VERSION=1.0.3 run_deploy)"
teardown

# 2. No env var: a local release left last-release.json behind.
setup
echo '{"version": "1.2.3"}' > "$SANDBOX/root/deploy/last-release.json"
check "falls back to deploy/last-release.json" "1.2.3" "$(run_deploy)"
teardown

# 3. No env var, no last-release.json (a fresh CI checkout on a webapp-only push):
#    keep publishing whatever is already live instead of inventing a version.
setup
mkdir -p "$SANDBOX/live/current"
echo '{"version": "1.0.9"}' > "$SANDBOX/live/current/version.json"
check "keeps the deployed version when told nothing" "1.0.9" "$(run_deploy)"
teardown

# 4. Nothing anywhere: refuse, rather than publish a guess.
setup
check "refuses to deploy with no version at all" "exit:1" "$(run_deploy)"
teardown

# 5. The HTML badge must carry the same version as version.json. These are
#    written by two different mechanisms (heredoc and sed) and have drifted.
setup
BERRYDB_VERSION=2.4.6 run_deploy >/dev/null
check "index.html badge matches" "BerryDB v2.4.6" \
    "$(grep -oE 'BerryDB v[0-9.]+' "$SANDBOX/root/webapp/index.html" | head -1)"
check "version metadata requires macOS 15" "15.0" \
    "$(awk -F'"' '/"minMacOS"/ {print $4}' "$SANDBOX/root/webapp/public/version.json")"
teardown

# 6. Nothing may be left advertising an older version. This is the check that
#    matters: the ribbon said v1.0.3 while both download buttons still said
#    v1.0.2, because the rewrite only matched "BerryDB v<ver>". Asserting on the
#    whole page -- rather than on one badge -- catches the next spelling too.
setup
BERRYDB_VERSION=9.9.9 run_deploy >/dev/null
STALE=""
for page in index.html docs.html; do
    [ -f "$SANDBOX/root/webapp/$page" ] || continue
    HITS=$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' "$SANDBOX/root/webapp/$page" \
        | sort -u | grep -v '^v9\.9\.9$' || true)
    [ -n "$HITS" ] && STALE="$STALE $page:$(echo "$HITS" | tr '\n' ',')"
done
check "no page still advertises an older version" "" "$STALE"
teardown

echo
if [ "$FAIL" -eq 0 ]; then echo "all $PASS passed"; else echo "$FAIL failed, $PASS passed"; exit 1; fi
