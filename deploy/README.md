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

## 2. One-Time Setup: Enable In-App Updater (Sparkle Framework)

By default, builds do **not** embed Sparkle: the *Check for Updates…* menu item is a no-op (`NoopUpdater`). This preserves zero runtime external dependencies and enforces binary size limits (`scripts/check-size.sh`) during development and testing.

The updater code (`App/Sources/AppUpdater.swift`) is gated by `#if canImport(Sparkle)`, activating automatically once the framework is linked.

To enable Sparkle for a production release:

1. Uncomment the two Sparkle lines in `Package.swift`:
   - `.package(url: "https://github.com/sparkle-project/Sparkle.git", ...)`
   - `.product(name: "Sparkle", package: "Sparkle")` in the `BerryApp` target.
   `canImport(Sparkle)` evaluates to `true`, compiling `SparkleUpdater`.

2. Embed and re-sign the framework into the bundle **after** `swift build -c release` and **before** the outer `codesign`:

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

3. Add `Sparkle.framework` to the allowlist in `scripts/check-size.sh` for release builds.

## 3. Release Process

Push a tag. Everything else is automatic.

```sh
git tag v1.0.3
git push --tags
```

`.github/workflows/release.yml` then builds, signs, notarizes, checks the app size, publishes the DMG and appcast to R2, creates a GitHub Release and updates the website's version. Credentials come from GitHub Secrets, not from `deploy/.env`.

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
