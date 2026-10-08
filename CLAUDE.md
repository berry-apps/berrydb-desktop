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

## Code and comment quality

Condition 3 says what a comment must not contain. This section says what it
must be. Every rule comes from something that actually landed here.

- **A comment states why the code is the way it is**, not what the next line
  does. Name the constraint, the observed fact, or the alternative that was
  rejected and why. If removing the comment loses no information, remove it.
- **No planning vocabulary.** These mean nothing to someone reading the public
  repo:
  - feature, principle or decision IDs (`AI-36`, `NS-05`, `N3`, `Q17`);
  - plan structure (`Phase C`, `Task 11`, `PR A`);
  - paths into private docs (`docs/architecture/…`, `docs/superpowers/…`).

  Write the rule itself instead, e.g. "batches of at most 1000 rows, so the
  grid never holds a whole table", not "(N3)". IDs belong in the planning
  docs and commits outside this repo.
- **Claims about an external system carry their evidence.** A comment that
  says how AWS, Postgres or a protocol behaves either names how it was
  verified ("verified against dynamodb-local 3.3.0") or links the public
  vendor documentation. An unverified claim is a guess, and guesses rot.
- **Complete sentences at the code's own indentation.** A comment line at a
  one-space indent, or a sentence that stops mid-way (` // See`), is residue
  from references cut out of a comment. Rewrite the whole comment; do not
  leave the fragment.
- **No dead code, no speculative abstraction, no `TODO` without an issue
  link.** Code that might be needed later is written later.
- **`scripts/check-comment-hygiene.sh` enforces the mechanical part.** It
  covers planning IDs, private paths, process narration, Vietnamese outside
  `Tests/`, and the one-space indent. It checks only the lines a change adds,
  and CI runs it on every pull request. Run it locally before pushing:
  `scripts/check-comment-hygiene.sh origin/main`.
- **Existing debt.** About 1,200 older lines still violate these rules. Fix
  them in their own `chore:` change, never mixed into a feature. Do not
  copy their style; "it matches the surrounding code" does not apply to
  residue.

## Toolchain — CI is not your machine

CI builds with the Swift toolchain of the `macos-15` runner (Swift 6.1 as of
this writing). A newer local Xcode accepts strict-concurrency code that 6.1
rejects, e.g. a closure returning a non-`Sendable` value across an isolation
boundary. A green local `make test` is not proof that CI compiles. When a
non-`Sendable` payload must cross a closure or actor boundary, wrap it in an
immutable `@unchecked Sendable` struct, the pattern `DynamoDBPage` and
`ResultBox` already use. Treat the pull request's CI run as the
authoritative build.

## Store migrations are append-only

Never rename, reorder or edit a migration registered in `BerryStore.migrator`
once any build, including a development build run against a real store, may
have applied it; add a new migration instead. GRDB records only the
identifier of an applied migration, so when `v30-mcp-project-grant` was
rewritten in place as `v30-mcp-project`, every store that had run the earlier
build failed to open with `table "mcp_project" already exists` and the app
started without its connection profiles. If a migration must be withdrawn
anyway, add its identifier and the tables it created to
`BerryStore.supersededMigrations`, so stores that applied it recover on the
next open.

## Pull requests

- English only. Title is a conventional commit (`feat(dynamodb): …`). Link
  the issue with `Closes #N`, or `Refs #N` when the PR delivers only part
  of it.
- The body states what was verified and how: tests, real servers, the
  running app. It says plainly what was not verified. No internal IDs or
  private paths, and no account data such as ARNs, account IDs or hostnames
  from someone's environment.

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
