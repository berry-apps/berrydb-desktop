#!/usr/bin/env bash
# Rejects comment and text patterns that do not belong in this public repository,
# on lines a change ADDS relative to a base ref. Pre-existing lines are never
# reported, so the check can gate new work without first rewriting history.
#
# Rules (each reported as [rule] with file:line):
#   internal-id     A planning ID in a comment: feature IDs (AI-36, NS-05, ...),
#                   principle IDs (N1-N9) or decision IDs (Q1-Q99). They point at
#                   documents outside this repository and mean nothing to readers.
#   internal-path   A path into the private planning docs (docs/architecture/...,
#                   docs/superpowers/...), anywhere on the line.
#   narration       Process narration in a comment: "Phase D", "Task 3", "PR A",
#                   "as requested", "the user asked". Comments state the technical
#                   reason, not how the change came about.
#   non-english     Vietnamese text outside Tests/ (test data is the one exception).
#   comment-indent  A Swift comment at a one-space indent, the shape left behind
#                   when references were cut out of a comment mid-sentence.
#
# Usage:  scripts/check-comment-hygiene.sh [BASE]     (default BASE: origin/main)
# Exit:   0 clean, 1 violations found, 2 usage error.
set -euo pipefail

BASE="${1:-origin/main}"
if ! git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null; then
    echo "check-comment-hygiene: unknown base ref '$BASE'" >&2
    exit 2
fi

# Three-dot diff: only what this branch added since it forked from BASE. This
# script and its test are excluded: they must spell out the very patterns they
# reject.
git diff --no-color --no-ext-diff -U0 --diff-filter=AM "$BASE"...HEAD -- '*.swift' '*.sh' '*.py' \
    ':(exclude)scripts/check-comment-hygiene.sh' ':(exclude)scripts/test-check-comment-hygiene.sh' \
| perl -CSD -ne '
    BEGIN {
        $ids    = qr/\b(?:(?:AI|CT|DI|DL|ED|KN|NS|TI|TM|TR|UD|XN)-\d{2}|N[1-9]|Q[1-9]\d?)\b/;
        $paths  = qr{\bdocs/(?:architecture|superpowers|feature|reviews|reports|draft|feedback)/};
        $labels = qr/\b(?:Phase [A-Z]|Task \d+|PR [AB])\b/;
        $asked  = qr/\b(?:as requested|the user asked|per the user)\b/i;
        $vi     = qr/[\x{0102}\x{0103}\x{0110}\x{0111}\x{01A0}\x{01A1}\x{01AF}\x{01B0}\x{1EA0}-\x{1EF9}]/;
        ($file, $line, $bad) = ("", 0, 0);
    }
    if (m{^\+\+\+ b/(.*)$}) { $file = $1; next }
    if (/^\+\+\+ /)        { $file = ""; next }
    if (/^@@ -\S+ \+(\d+)/) { $line = $1; next }
    next unless /^\+/ && $file ne "";

    chomp(my $text = substr($_, 1));
    my $comment;
    if ($file =~ /\.swift$/) {
        $comment = $1 if $text =~ m{//(.*)$} or $text =~ m{^\s*\*(.*)$};
    } else {
        $comment = $1 if $text =~ /(?:^|\s)#(.*)$/;
    }

    my @hits;
    push @hits, "internal-id"    if defined $comment && $comment =~ $ids;
    push @hits, "internal-path"  if $text =~ $paths;
    push @hits, "narration"      if defined $comment && ($comment =~ $labels || $comment =~ $asked);
    push @hits, "non-english"    if $text =~ $vi && $file !~ m{(?:^|/)Tests/};
    push @hits, "comment-indent" if $file =~ /\.swift$/ && $text =~ m{^ //};
    for my $rule (@hits) { print "$file:$line: [$rule] $text\n"; $bad = 1 }
    $line++;
    END { exit $bad }
'
