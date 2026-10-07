#!/usr/bin/env bash
# Tests check-comment-hygiene.sh by running the real script inside throwaway git
# repositories: a base commit, then a commit that adds the line under test.
#
# The fixtures are lines that actually reached this public repo: internal
# feature/principle IDs such as "(N3)", and comment lines left at a one-space
# indent with their sentence cut off (" // See") after internal references were
# stripped from them. A stub that only matched lines invented for the test would
# not prove the check catches what really slipped through.
#
# Usage:  scripts/test-check-comment-hygiene.sh [path/to/check-comment-hygiene.sh]
set -uo pipefail

SCRIPT_UNDER_TEST="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-comment-hygiene.sh}"
[ -f "$SCRIPT_UNDER_TEST" ] || { echo "no such script: $SCRIPT_UNDER_TEST" >&2; exit 1; }
SCRIPT_UNDER_TEST="$(cd "$(dirname "$SCRIPT_UNDER_TEST")" && pwd)/$(basename "$SCRIPT_UNDER_TEST")"

PASS=0; FAIL=0

# A repository whose base commit holds one Swift file with an already-present
# violation, so every case also proves that pre-existing lines are not reported.
setup() {
    SANDBOX="$(mktemp -d)"
    git -C "$SANDBOX" init -q -b main
    git -C "$SANDBOX" config user.email test@example.com
    git -C "$SANDBOX" config user.name test
    mkdir -p "$SANDBOX/Packages/Kit/Sources" "$SANDBOX/Packages/Kit/Tests" "$SANDBOX/scripts"
    printf 'let a = 1\n // pre-existing residue (N3)\n' > "$SANDBOX/Packages/Kit/Sources/Old.swift"
    git -C "$SANDBOX" add -A
    git -C "$SANDBOX" commit -q -m base
    git -C "$SANDBOX" branch base
}
teardown() { rm -rf "$SANDBOX"; }

# Appends LINE to FILE (inside the sandbox), commits it, and runs the checker
# against the base branch. Echoes "exit:<status>" followed by the output.
run_with_added_line() { # file line
    mkdir -p "$SANDBOX/$(dirname "$1")"
    printf 'let pad = 0\n%s\n' "$2" >> "$SANDBOX/$1"
    git -C "$SANDBOX" add -A
    git -C "$SANDBOX" commit -q -m change
    OUT="$(cd "$SANDBOX" && bash "$SCRIPT_UNDER_TEST" base 2>&1)"
    STATUS=$?
    printf 'exit:%s\n%s' "$STATUS" "$OUT"
}

check() { # name expected-substring actual
    if printf '%s' "$3" | grep -qF -- "$2"; then
        printf '  ok   %s\n' "$1"; PASS=$((PASS + 1))
    else
        printf '  FAIL %s\n       expected to contain: %s\n' "$1" "$2"; FAIL=$((FAIL + 1))
        printf '%s\n' "$3" | sed 's/^/       | /'
    fi
}

check_absent() { # name unexpected-substring actual
    if printf '%s' "$3" | grep -qF -- "$2"; then
        printf '  FAIL %s\n       did not expect: %s\n' "$1" "$2"; FAIL=$((FAIL + 1))
        printf '%s\n' "$3" | sed 's/^/       | /'
    else
        printf '  ok   %s\n' "$1"; PASS=$((PASS + 1))
    fi
}

case_expect() { # name file line expected-substring
    setup; local got; got="$(run_with_added_line "$2" "$3")"; check "$1" "$4" "$got"; teardown
}
case_clean() { # name file line
    setup; local got; got="$(run_with_added_line "$2" "$3")"; check "$1" "exit:0" "$got"; teardown
}

echo "testing $SCRIPT_UNDER_TEST"

case_expect "principle ID in a comment" Packages/Kit/Sources/New.swift \
    '    /// Streams every page as batches of ≤1000 rows (N3).' "[internal-id]"
case_expect "feature ID in a comment" Packages/Kit/Sources/New.swift \
    '    // Behaviour defined by NS-05.' "[internal-id]"
case_expect "decision ID in a comment" Packages/Kit/Sources/New.swift \
    '    // Chosen per Q16.' "[internal-id]"
case_expect "feature ID in a shell comment" scripts/tool.sh \
    '# See AI-36 for the contract.' "[internal-id]"
case_clean "algorithm and encoding names are not IDs" Packages/Kit/Sources/New.swift \
    '    // Hashes with SHA-256 and reads UTF-16 offsets.'
case_clean "an ID-like token outside a comment is not reported" Packages/Kit/Sources/New.swift \
    '    let label = "N3"'
case_expect "private docs path anywhere on the line" Packages/Kit/Sources/New.swift \
    '    let doc = "docs/architecture/12-nosql-vector.md"' "[internal-path]"
case_expect "process narration: phase label" Packages/Kit/Sources/New.swift \
    '/// Read-only sibling of `UserManagementView` (Phase D,' "[narration]"
case_expect "process narration: request wording" Packages/Kit/Sources/New.swift \
    '    // Added as requested.' "[narration]"
case_clean "ordinary use of the word task" Packages/Kit/Sources/New.swift \
    '    // Retry the task 3 times before giving up.'
case_expect "Vietnamese in a source comment" Packages/Kit/Sources/New.swift \
    '    // Sửa lỗi phân trang.' "[non-english]"
case_clean "Vietnamese test data is allowed" Packages/Kit/Tests/RoundTripTests.swift \
    '    let sample = "Xin chào thế giới"'
case_expect "one-space comment indent left by stripping references" Packages/Kit/Sources/New.swift \
    ' // See' "[comment-indent]"
case_clean "normally indented comment" Packages/Kit/Sources/New.swift \
    '    // Keeps the cursor stable across reloads.'
case_clean "the checker's own rule descriptions are exempt" scripts/check-comment-hygiene.sh \
    '#   internal-id     A planning ID in a comment: AI-36, NS-05, N3, Q17.'
case_clean "the checker's own fixtures are exempt" scripts/test-check-comment-hygiene.sh \
    "    '    // Sửa lỗi phân trang.' \"[non-english]\""

setup
got="$(run_with_added_line Packages/Kit/Sources/New.swift '    // Defined by NS-05.')"
check "reports file and new-side line number" "Packages/Kit/Sources/New.swift:2: [internal-id]" "$got"
check_absent "does not report the pre-existing violation" "Old.swift" "$got"
teardown

setup
got="$(cd "$SANDBOX" && bash "$SCRIPT_UNDER_TEST" no-such-ref 2>&1; echo "exit:$?")"
check "unknown base ref is a usage error" "exit:2" "$got"
teardown

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
