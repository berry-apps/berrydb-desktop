#!/bin/bash
# Stapling helper sourced by deploy/release.sh. `xcrun stapler` fetches the
# notarization ticket from Apple's CloudKit service, and that fetch drops the
# connection now and then on GitHub's runners (NSURLErrorDomain -1005, "The
# validate action failed! Error 68") after the submission itself was
# accepted. A dropped fetch is not a verdict on the build, so each call gets
# a few attempts with a pause in between before the release gives up.
#
# STAPLE_ATTEMPTS (default 5) and STAPLE_RETRY_DELAY seconds (default 20)
# exist so deploy/test-staple.sh can run in a second.

# staple_and_validate <path> — staples <path> and validates the result,
# retrying both on failure. Returns non-zero once the attempts run out.
staple_and_validate() {
  attempts="${STAPLE_ATTEMPTS:-5}"
  delay="${STAPLE_RETRY_DELAY:-20}"
  attempt=1
  until xcrun stapler staple "$1" && xcrun stapler validate "$1"; do
    if [ "$attempt" -ge "$attempts" ]; then
      echo "✗ stapling $1 failed after $attempt attempts" >&2
      return 1
    fi
    echo "▸ stapler failed (attempt $attempt of $attempts), retrying in ${delay}s…"
    attempt=$((attempt + 1))
    sleep "$delay"
  done
}
