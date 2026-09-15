# BerryDB Desktop — Working Agreement

This repo is public (`berry-apps/berrydb-desktop`, Apache 2.0) since 2026-09-15. It
went through a deliberate pass to be publishable and stays held to the same bar
on every change after that, not just the one that got it there. If you were
spawned into an isolated worktree of this repo specifically because the rules
live here, not only in an umbrella repo you might not see — this file has to
carry the whole story on its own.

## The four publication conditions

Everything below exists to keep these true. If a change would violate one,
that is a reason to stop and say so, not to make an exception quietly.

1. **No security regressions.** Don't weaken signing, notarization, or any
   existing guard (`scripts/check-size.sh`'s bundle/LGPL/FreeTDS-pin checks,
   the codesign steps in `deploy/release.sh`, `SSH_ASKPASS` for tunnel
   passphrases). Secrets (`SPARKLE_PRIVATE_ED_KEY`, signing identities, R2
   credentials) go through stdin or GitHub Actions secrets — never a CLI
   argument (visible in `ps`), never committed, never logged.
2. **No performance regressions.** `make test` passing says nothing about
   latency or memory. Ask what runs per-token or per-row and whether its cost
   grows with accumulated data before touching a streaming or grid path. Never
   remove a throttle/debounce without measuring — read the comment explaining
   why it exists first. `scripts/measure-performance.sh` exists to check
   startup/memory claims against reality before they're published anywhere.
3. **No human↔agent conversation in code, comments, or commits.** Never write
   a comment or commit message that narrates a request — no "the user asked
   for X", "as requested", no quoting a prompt, no first/second person framed
   as a conversation. State the technical reasoning and the observed fact,
   the way `deploy/upload-release.py`, `deploy/release.sh`, and
   `scripts/check-size.sh` already do: dense, factual, explains *why* a
   non-obvious choice was made. If a bug was found from something a user
   said, describe the observed behavior ("reported from use: X did not
   happen"), never the sentence they said it in.
4. **Comments and commit messages in consistent international English.** No
   Vietnamese, no other language, anywhere in this repo — not in code, not in
   commit messages, not in issue or PR text. (Vietnamese unicode strings that
   are deliberate *test data* — e.g. round-tripping through a database's
   `text`/`nvarchar` column — are the one standing exception; that is data
   under test, not a comment.)

## Attribution — placement matters as much as presence

`Co-Authored-By` and `🤖 Generated with Claude Code` belong ONLY in the git
commit trailer and the PR body footer, respectively — exactly as the current
session's own attribution instructions specify (the exact line changes with
whichever model is active; don't hardcode a name here, use what you're told
at the time). Never put either inside a source comment, a code string, an
appcast/release artifact, or an issue/PR body's main text. Being visible in
`git log` and on the PR page is the whole point; showing up anywhere else is
noise in a public repo.

## Git workflow

- `gh` acts as GitHub user `quangtaned`. Confirm with `gh api user --jq .login`
  before any write (push, PR, issue, release edit). Never switch accounts.
- Never commit to `main`. Branch first: `git checkout -b <type>/<short-name>`.
  Run `git branch --show-current` immediately before every commit — don't
  trust what you remember being on.
- Push with `git push -u origin HEAD`, then verify the server actually has
  your commit before claiming it does:
  `git log --oneline -1 HEAD` vs `gh pr view <n> --json headRefOid --jq .headRefOid`.
- Open PRs against `main`. Do not merge your own PR — a human reviews and
  merges, per this project's standing workflow.
- One PR per logical change. Link the GitHub issue it closes (`Closes #N`) and
  comment on that issue with the PR link once it exists.
- Check `git status` before touching anything — an in-progress checkout can
  carry someone else's uncommitted work. Read the diff of anything you didn't
  write before staging it, and say whose it looks like rather than sweeping
  it into your own commit.

## Test style — match what's already here before inventing a new pattern

- Swift: `Testing` framework, `@Suite`/`@Test`, TDD — write the failing test,
  run it, read the real failure, then implement. `make test` must stay green
  (~1428 tests as of this writing).
- Python release tooling (`deploy/upload-release.py` etc.): stdlib-only tests
  with a stub like `FakeS3` in `deploy/test_upload_release.py` — no live
  network, no real credentials.
- Shell scripts: run the *real* script against a throwaway sandbox rather than
  mocking it — see `webapp/deploy/test-deploy-version.sh`, which copies the
  real pages into a temp tree and asserts on what the real script produces.
- If a real Apple Developer identity, real Sparkle key, or real macOS version
  other than the one you're running on would be needed to fully verify
  something, say exactly that in the PR rather than asserting untested
  confidence — this project has been burned before by a warning that turned
  out to matter and a claim that turned out not to survive contact with the
  real artifact.

## Where else to look

`CONTRIBUTING.md` (human-facing setup and PR process), `SECURITY.md`
(vulnerability reporting), `THIRD-PARTY-NOTICES.md` (every dependency's
license — update it in the same PR that adds or changes a dependency),
`deploy/README.md` (release pipeline and required secrets/variables).
