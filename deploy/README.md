# BerryDB — Release & Distribution

Guide for signing, notarizing, and releasing BerryDB with automated updates via Sparkle.
All secrets reside in `deploy/.env` (gitignored) — see `deploy/.env.example`. **NEVER commit real credentials.**

## 1. One-Time Setup: Sparkle Update Keys (EdDSA)

```sh
# Generate key pair from a Sparkle checkout or Sparkle release:
./bin/generate_keys            # Saves private key into Keychain, prints public key
```

- Public key -> Set `SU_PUBLIC_ED_KEY` in `deploy/.env` (embedded into `Info.plist`).
- Private key resides in Keychain, used by `sign_update` during release packaging.
- Set `SPARKLE_BIN` to `sign_update` if it is not in your `PATH` or `.build`.

## 2. In-App Updater (Sparkle Framework)

Sparkle is an unconditional dependency: both the `.package(...)` entry and the
`BerryApp` target's `Sparkle` product in `Package.swift` are always active, so
`#if canImport(Sparkle)` in `App/Sources/AppUpdater.swift` compiles the real
`SparkleUpdater` for every build — `swift build`/`swift test`/`swift run`
included, not only a packaged release. `scripts/check-size.sh`'s
runtime-dependency guard already allowlists `Sparkle.framework` as a
permanent embedded exception (see the comment next to its `FOREIGN` check),
so there is nothing to opt into or add here.

`scripts/make_app.sh` copies any `.framework` produced by the build into
`Contents/Frameworks/` when it assembles the `.app`. For a release build,
`deploy/release.sh` then re-signs `Sparkle.framework` from the inside out,
after `swift build -c release` and before the outer `codesign`:

```sh
FW="$(swift build -c release --show-bin-path)/Sparkle.framework"
mkdir -p dist/BerryDB.app/Contents/Frameworks
ditto "$FW" dist/BerryDB.app/Contents/Frameworks/Sparkle.framework

# Sign from inside out: XPCServices + Autoupdate, then framework
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
  dist/BerryDB.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/*.xpc
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
  dist/BerryDB.app/Contents/Frameworks/Sparkle.framework
```

(`deploy/release.sh` already runs this; it's shown here only for anyone
reproducing the release process by hand — see "Fallback — releasing by hand"
below.)

Whether `SparkleUpdater` is actually used at runtime is a separate check in
`makeUpdater()` (`App/Sources/AppUpdater.swift`): it only returns
`SparkleUpdater` for a real `.app` bundle whose `Info.plist` carries a
non-empty `SUFeedURL` — `scripts/make_app.sh` only writes that key when
`SU_PUBLIC_ED_KEY` is set (a real release build). Everything else, including
a plain `swift run` or a dev build packaged by `scripts/run.sh`, gets
`NoopUpdater` and the *Check for Updates…* menu item is a no-op, even though
the real Sparkle class is compiled in either way.

## 3. Release Process

Push a tag. Everything else is automatic.

```sh
git tag v1.0.3
git push --tags
```

`.github/workflows/release.yml` then builds, signs, notarizes, checks the app size, publishes the DMG and appcast to R2, creates a GitHub Release, updates the website's version and, once a reviewer approves, announces the release on Telegram and a Facebook Page (see section 8). Credentials come from GitHub Secrets, not from `deploy/.env`.

To rehearse without publishing, run the workflow manually from the Actions tab with `dry_run` enabled: it builds, signs and notarizes, then stops before R2 and before creating the Release, and attaches the DMG as a workflow artifact.

**Fallback — releasing by hand.** Still supported and unchanged, for when Actions is unavailable:

```sh
# One-time. A venv, not a global install: a Homebrew-managed python3 refuses
# the latter under PEP 668.
python3 -m venv .venv-release
.venv-release/bin/pip install -r deploy/requirements.txt

make release 1.0.3
.venv-release/bin/python deploy/upload-release.py
```

- `deploy/release.sh` produces `dist/BerryDB-<version>.dmg` (drag-and-drop installer for Applications, notarized and stapled) and `deploy/last-release.json`. The inner app is stapled for offline execution. It signs the update through `scripts/sign-update.sh`, which reads the private key from the Keychain locally and from `SPARKLE_PRIVATE_ED_KEY` on a runner.
- `deploy/upload-release.py` generates `appcast.xml`, uploads release files to Cloudflare R2, and purges CDN cache. It also publishes an alias `BerryDB-latest.dmg` for static download links. **The release history lives in R2**, not in the tracked `deploy/releases.json` — that file only seeds the very first run, and editing it afterwards changes nothing.
- Before building the appcast, `upload-release.py` also calls `generate_deltas()`, which reconstructs each of the last `DELTA_WINDOW` (5, matching Sparkle's own `generate_appcast` default) prior `.dmg` releases by downloading them from R2 and mounting them (`scripts/extract-app-from-dmg.sh`), diffs each against the freshly built `dist/BerryDB.app` with Sparkle's `BinaryDelta` tool (`scripts/build-delta.sh`), signs the result with `scripts/sign-update.sh` (the same helper `release.sh` uses for the DMG), and uploads it to R2. Each successfully generated delta appears in the newest appcast item as a `sparkle:deltaFrom` enclosure alongside the full-DMG one. A delta that can't be built for any reason (old DMG missing, `BinaryDelta` unavailable or failing, an unsigned result) is logged and skipped — it never fails the release, since the full-DMG item is what every client without a matching delta falls back to.

## 4. Pre-Release Security Checklist

- [ ] **Verify License Public Key**: Set `LicenseManager.devPublicKeyBase64` (`Packages/BerryLicense/Sources/LicenseManager.swift`) to the production backend's public key.
- [ ] **Production Backend HTTPS**: Ensure production backend uses HTTPS (`BERRYDB_BACKEND_URL=https://...`) — client rejects non-loopback `http://`.
- [ ] **Database TLS**: Encourage users to use certificate validation for production database connections.

## 5. Required Environment Variables (`deploy/.env`)

| Category | Variables | Description |
| :--- | :--- | :--- |
| **Apple Signing & Notarization** | `APPLE_ID`, `APP_SPEC_PASSWORD`, `SIGNING_IDENTITY`, `APPLE_TEAM_ID` | Developer ID cert and notarization credentials |
| **Sparkle Updates** | `SU_PUBLIC_ED_KEY`, `SU_FEED_URL`, `SPARKLE_BIN` | Public EdDSA verification key and feed URL |
| **Cloudflare R2** | `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET` | S3-compatible credentials and release bucket |
| **CDN Cache Purge** | `CF_ZONE_ID`, `CF_API_TOKEN` | Purges Cloudflare cache upon upload |
| **Download URL** | `DOWNLOAD_BASE_URL` | Base URL for generated download links |

## 6. App Icon

Place `deploy/icon-1024.png` (1024x1024) in the deploy directory. `scripts/make_app.sh` renders `AppIcon.icns` using `sips` and `iconutil` and bundles it into the app.

## 7. Notes

- BerryDB runs with Apple Hardened Runtime (`deploy/BerryDB.entitlements`).
- Appcast and release manifest (`releases.json`) are generated automatically during the release pipeline.

## 8. Release Announcements

After a real release is published, `.github/workflows/announce-release.yml` posts it to a Telegram channel and to a Facebook Page, once a person approves. A dry run announces nothing. X is posted by hand. Facebook Groups and personal profiles are not covered: Meta's API does not post to them.

### What is posted, and when

`release.yml` calls the workflow after the GitHub Release exists. It does not listen for the `release` event, because the Release is created with the workflow's `GITHUB_TOKEN`, and events caused by `GITHUB_TOKEN` do not start new workflow runs ([GitHub docs](https://docs.github.com/en/actions/using-workflows/triggering-a-workflow#triggering-a-workflow-from-a-workflow)). The workflow has two jobs:

1. `preview` renders the exact message for each channel into the run's job summary. It posts nothing and receives no channel secret.
2. `post` is bound to the `release-announcement` environment, so it waits for a reviewer before it starts. The reviewer reads the preview's summary, then approves or rejects. The release notes are read again when `post` runs, so editing the Release before approving changes what is posted.

The messages:

- **Telegram**: the release name, the release notes as plain text (headings without `#`, list items as bullets, bold markers removed, links kept), and the release page URL last. Telegram limits a message to 4096 characters ([Bot API](https://core.telegram.org/bots/api#sendmessage)), so a long body is shortened with an ellipsis and the URL is never cut. No `parse_mode` is sent, so release text cannot trip Telegram's Markdown parser.
- **Facebook Page**: the same name and notes as the post text, with the release page attached as the post's link.

To announce or re-announce a tag by hand, run **Announce Release** from the Actions tab with the tag (for example `v1.0.8`). A failed run is retried with *Re-run failed jobs*, which posts to every configured channel again, including one that already succeeded.

A Release run that is waiting for approval has not finished, so a later Release run stays pending in the same concurrency group (`berrydb-release`) until it does ([GitHub docs](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)). Approve or reject promptly.

### One-time setup

1. **Create the environment.** Settings, Environments, New environment, named exactly `release-announcement`. Add yourself under *Required reviewers*. Optionally restrict *Deployment branches and tags* ([GitHub docs](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)).
2. **Add the secrets to that environment**, under *Environment secrets*, not as repository secrets. GitHub releases an environment's secrets only to a job that uses it, and only after its protection rules pass, so nothing can post before the environment is configured. A repository secret with the same name would be passed to the workflow as well; the environment's value takes precedence in `post`, but there is no reason to create one.

| Secret | Value |
| :--- | :--- |
| `TELEGRAM_BOT_TOKEN` | The bot's token |
| `TELEGRAM_CHAT_ID` | The channel as `@channelusername`, or its numeric id |
| `FACEBOOK_PAGE_ID` | The Page's id |
| `FACEBOOK_PAGE_ACCESS_TOKEN` | A Page access token, see below |

A channel is posted to only when both of its secrets are set. Setting one without the other fails the run before anything is posted; setting neither skips that channel, so the two channels can be enabled independently. `release.yml` passes the four secrets to the workflow by name. A called workflow only receives an environment secret when its caller passes it, even when the secret exists only in the environment ([GitHub docs](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)).

### Telegram

1. Message [@BotFather](https://t.me/BotFather) to create a bot and receive its token ([Telegram docs](https://core.telegram.org/bots)). Anyone holding the token controls the bot, so it goes only into the environment secret.
2. Add the bot to the channel as an administrator that is allowed to post messages (`can_post_messages` in the [Bot API](https://core.telegram.org/bots/api#chatmemberadministrator)).
3. Set `TELEGRAM_CHAT_ID` to `@channelusername` for a public channel. For a private channel use its numeric id, which appears as `chat.id` in the bot's `channel_post` updates ([`getUpdates`](https://core.telegram.org/bots/api#getupdates)) after something is posted in the channel.

### Facebook Page

1. Create an app on [Meta for Developers](https://developers.facebook.com/) and keep it in Development mode, with the person who manages the Page as a role user. An app in Development mode can only request permissions from role users ([App modes](https://developers.facebook.com/docs/development/build-and-test/app-modes)).
2. As a person who can manage the Page and has a role on the app, authorize the app through Facebook Login with the `pages_manage_posts` permission, plus the others Meta lists for publishing ([Pages API: posts](https://developers.facebook.com/docs/pages-api/posts)).
3. Exchange that short-lived user token for a long-lived one, then request the Page's token with `GET /{user-id}/accounts` ([long-lived tokens](https://developers.facebook.com/docs/facebook-login/guides/access-tokens/get-long-lived)). Meta documents that a Page access token obtained from a long-lived user token has no expiration date, and that it can still be invalidated under certain conditions. When posting starts failing with an OAuth error, generate a new token and replace the secret.
4. Set `FACEBOOK_PAGE_ID` to the Page's id and `FACEBOOK_PAGE_ACCESS_TOKEN` to the Page token. The Graph API version is the `GRAPH_API_VERSION` constant in `deploy/announce-release.py`.

The script's tests run with `python3 -m unittest deploy/test_announce_release.py` and never touch the network. To see what the next announcement would look like without posting anything: `GH_TOKEN=$(gh auth token) GITHUB_REPOSITORY=berry-apps/berrydb-desktop python3 deploy/announce-release.py --tag v1.0.8 --preview`.
