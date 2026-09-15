#!/usr/bin/env python3
"""Publish a BerryDB release: upload the notarized zip to Cloudflare R2, rebuild
the Sparkle appcast from the release history, upload it, and purge the CDN cache.

Reads deploy/last-release.json (written by deploy/release.sh) and appends it to
releases.json IN R2, which is the source of truth for the appcast. The tracked
deploy/releases.json only seeds the very first run and is frozen after that —
editing it changes nothing. Secrets come from deploy/.env (gitignored) — see
deploy/.env.example. Requires boto3 (see requirements.txt).

Nothing here signs the build; the
EdDSA signature is produced by release.sh and carried in last-release.json.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
DEPLOY = ROOT / "deploy"
SCRIPTS = ROOT / "scripts"

# Sparkle's own generate_appcast tool defaults to building binary deltas from
# only the most recent 5 versions up to the latest one (DEFAULT_MAXIMUM_DELTAS
# in generate_appcast/main.swift, sparkle-project/Sparkle @ 2.x — checked
# 2026-09), not the entire release history. We don't use generate_appcast (see
# build_appcast's docstring for why), but there's no reason to pick a
# different number than the tool designed for this: an appcast is re-fetched
# on every launch, and an unbounded fan of stale deltas nobody will ever apply
# just grows that download and the count of extra files kept on R2 forever,
# for versions almost nobody is still running.
DELTA_WINDOW = 5


def load_env() -> None:
    env = DEPLOY / ".env"
    if not env.exists():
        return
    for line in env.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip())


def require(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        sys.exit(f"✗ Missing required env: {name} (set it in .env)")
    return value


def r2_client():
    import boto3  # deferred so --help works without the dep

    account = require("R2_ACCOUNT_ID")
    return boto3.client(
        "s3",
        endpoint_url=f"https://{account}.r2.cloudflarestorage.com",
        aws_access_key_id=require("R2_ACCESS_KEY_ID"),
        aws_secret_access_key=require("R2_SECRET_ACCESS_KEY"),
        region_name="auto",
    )


HISTORY_KEY = "releases.json"


def _load_history(s3, bucket: str) -> list[dict]:
    """The release history, from R2 if it is there and the tracked file if not.

    R2 holds it because a CI runner's checkout is whatever main holds: merging into
    the tracked file and letting the VM be destroyed would drop every intermediate
    version from the appcast, silently. The tracked deploy/releases.json seeds the
    very first run and is frozen after that.
    """
    try:
        body = s3.get_object(Bucket=bucket, Key=HISTORY_KEY)["Body"].read()
        return json.loads(body)
    except s3.exceptions.NoSuchKey:
        local = DEPLOY / HISTORY_KEY
        if local.exists():
            print(f"• No {HISTORY_KEY} in R2 yet — seeding from the tracked copy")
            return json.loads(local.read_text())
        print(f"• No {HISTORY_KEY} in R2 and none tracked — starting a new history")
        return []


def record_release(s3, bucket: str) -> dict:
    """Merge last-release.json into the R2 history (newest first, deduped)."""
    last = json.loads((DEPLOY / "last-release.json").read_text())
    history = _load_history(s3, bucket)
    history = [r for r in history if r.get("version") != last["version"]]
    history.insert(0, last)
    s3.put_object(
        Bucket=bucket,
        Key=HISTORY_KEY,
        Body=(json.dumps(history, indent=2) + "\n").encode(),
        ContentType="application/json",
        CacheControl="no-cache",
    )
    return {"last": last, "history": history}


class _BinaryDeltaUnavailable(Exception):
    """BinaryDelta isn't available at all — a fact about the environment, not
    about any one version pair. Raised to stop trying further candidates
    instead of repeating the same failure for each one."""


def _build_one_delta(s3, bucket: str, scripts_dir: Path, work_dir: Path, new_app: Path, old: dict, last: dict) -> dict:
    old_file = old["file"]
    old_dmg = work_dir / old_file
    s3.download_file(bucket, old_file, str(old_dmg))

    old_app = work_dir / f"old-{old['version']}.app"
    extract = subprocess.run(
        [str(scripts_dir / "extract-app-from-dmg.sh"), str(old_dmg), str(old_app)],
        capture_output=True, text=True,
    )
    if extract.returncode != 0:
        raise RuntimeError(f"could not extract .app from {old_file}: {extract.stderr.strip()}")

    delta_name = f"BerryDB-{old['version']}-{last['version']}.delta"
    delta_path = work_dir / delta_name
    built = subprocess.run(
        [str(scripts_dir / "build-delta.sh"), str(old_app), str(new_app), str(delta_path)],
        capture_output=True, text=True,
    )
    if built.returncode == 2:
        raise _BinaryDeltaUnavailable(built.stderr.strip())
    if built.returncode != 0:
        raise RuntimeError(f"BinaryDelta failed for {old['version']} -> {last['version']}: {built.stderr.strip()}")

    signed = subprocess.run(
        [str(scripts_dir / "sign-update.sh"), str(delta_path)],
        capture_output=True, text=True,
    )
    sig = signed.stdout.strip()
    if signed.returncode != 0 or not sig:
        raise RuntimeError(f"could not sign delta {delta_name}: {signed.stderr.strip() or 'empty signature'}")

    length = delta_path.stat().st_size
    print(f"▸ Uploading {delta_name} → r2://{bucket}/")
    s3.upload_file(str(delta_path), bucket, delta_name, ExtraArgs={"ContentType": "application/octet-stream"})
    return {"deltaFrom": old["version"], "file": delta_name, "length": length, "edSignature": sig}


def generate_deltas(
    s3, bucket: str, new_app: Path, last: dict, history: list[dict], scripts_dir: Path = SCRIPTS,
) -> list[dict]:
    """Build binary deltas from up to DELTA_WINDOW versions preceding `last` to
    `last` itself, sign each with the same EdDSA key as everything else, and
    upload them to R2. Returns the delta records for build_appcast to attach
    to `last["version"]`.

    Never raises and never fails the release: a delta that can't be built (old
    DMG missing from R2, BinaryDelta unavailable or failing, the source .app
    unreconstructable, an empty signature) is logged and skipped. Deltas are
    strictly additive on top of the full-DMG item, which is what every client
    without a matching delta falls back to.
    """
    if not new_app.is_dir():
        print(f"• Skipping deltas ({new_app} not found — nothing to diff the old versions against)")
        return []

    candidates = [r for r in history if r["version"] != last["version"]][:DELTA_WINDOW]
    deltas = []
    if not candidates:
        return deltas

    work_dir = Path(tempfile.mkdtemp(prefix="berrydb-delta-"))
    try:
        for old in candidates:
            if not old.get("file", "").endswith(".dmg"):
                print(f"• Skipping delta from {old['version']} (not a .dmg release)")
                continue
            try:
                deltas.append(_build_one_delta(s3, bucket, scripts_dir, work_dir, new_app, old, last))
            except _BinaryDeltaUnavailable as exc:
                print(f"• Skipping all remaining deltas (BinaryDelta unavailable): {exc}")
                break
            except Exception as exc:  # noqa: BLE001 - a delta failure must never fail the release
                print(f"• Skipping delta from {old['version']}: {exc}")
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)
    return deltas


def _quoted(value: str) -> str:
    return escape(value, {chr(34): "&quot;"})


def build_appcast(history: list[dict], download_base: str, deltas_by_version: dict[str, list[dict]] | None = None) -> str:
    """Render the Sparkle appcast. Not generate_appcast — see the module
    docstring for why this project writes the XML itself.

    deltas_by_version maps a release's version string to the list of delta
    records generate_deltas produced for it (each: deltaFrom, file, length,
    edSignature). In practice only the newest release in `history` ever has
    entries here — see generate_deltas — but any version present here gets a
    <sparkle:deltas> block, so an older entry that already has one (e.g. a
    rebuild of a stale appcast.xml) is preserved rather than special-cased.
    """
    deltas_by_version = deltas_by_version or {}
    items = []
    for r in history:
        url = f"{download_base.rstrip('/')}/{r['file']}"
        # Sparkle 2 installs from a .dmg or a .zip; set the enclosure type so the
        # feed is explicit about which.
        mime = "application/x-apple-diskimage" if r["file"].endswith(".dmg") else "application/octet-stream"
        sig = f' sparkle:edSignature="{_quoted(r["edSignature"])}"' if r.get("edSignature") else ""

        deltas_block = ""
        version_deltas = deltas_by_version.get(r["version"]) or []
        if version_deltas:
            delta_enclosures = []
            for d in version_deltas:
                delta_url = f"{download_base.rstrip('/')}/{d['file']}"
                delta_sig = f' sparkle:edSignature="{_quoted(d["edSignature"])}"' if d.get("edSignature") else ""
                delta_enclosures.append(
                    f'        <enclosure url="{escape(delta_url)}" '
                    f'sparkle:deltaFrom="{_quoted(d["deltaFrom"])}" '
                    f'length="{int(d["length"])}" type="application/octet-stream"{delta_sig} />'
                )
            deltas_block = "\n      <sparkle:deltas>\n" + "\n".join(delta_enclosures) + "\n      </sparkle:deltas>"

        items.append(f"""    <item>
      <title>Version {escape(r['version'])}</title>
      <pubDate>{escape(r.get('pubDate', ''))}</pubDate>
      <sparkle:version>{escape(str(r.get('build', r['version'])))}</sparkle:version>
      <sparkle:shortVersionString>{escape(r['version'])}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(r.get('minimumSystemVersion', '15.0'))}</sparkle:minimumSystemVersion>
      <enclosure url="{escape(url)}" length="{int(r['length'])}" type="{mime}"{sig} />{deltas_block}
    </item>""")
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>BerryDB</title>
    <link>{escape(download_base.rstrip('/'))}/appcast.xml</link>
    <description>BerryDB updates</description>
    <language>en</language>
{chr(10).join(items)}
  </channel>
</rss>
"""


def purge_cache(urls: list[str]) -> None:
    zone = os.environ.get("CF_ZONE_ID")
    token = os.environ.get("CF_API_TOKEN")
    if not (zone and token):
        print("• Skipping CDN purge (CF_ZONE_ID / CF_API_TOKEN not set)")
        return
    body = json.dumps({"files": urls}).encode()
    req = urllib.request.Request(
        f"https://api.cloudflare.com/client/v4/zones/{zone}/purge_cache",
        data=body,
        method="POST",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as resp:
        ok = json.load(resp).get("success")
        print(f"• CDN purge: {'ok' if ok else 'FAILED'}")


def main() -> None:
    load_env()
    bucket = require("R2_BUCKET")
    # Base URL for public release downloads.
    download_base = require("DOWNLOAD_BASE_URL")

    s3 = r2_client()
    merged = record_release(s3, bucket)
    last, history = merged["last"], merged["history"]
    zip_path = ROOT / last["path"]
    if not zip_path.exists():
        sys.exit(f"✗ Release artifact missing: {zip_path} (run deploy/release.sh first)")

    print(f"▸ Uploading {last['file']} → r2://{bucket}/")
    s3.upload_file(str(zip_path), bucket, last["file"],
                   ExtraArgs={"ContentType": "application/octet-stream"})

    # A stable "always latest" alias for direct-download links (e.g. the
    # website's download button), uploaded ALONGSIDE the versioned object
    # above — never replacing it. Sparkle's appcast items each carry a
    # signature/length tied to their OWN versioned filename (build_appcast
    # above); collapsing every release onto one shared key would leave every
    # older appcast entry pointing at content whose signature no longer
    # matches, and a user mid-download during a release could get served a
    # half-old/half-new file if a fixed key were the ONLY one ever written.
    latest_key = f"BerryDB-latest{Path(last['file']).suffix}"
    print(f"▸ Uploading {latest_key} → r2://{bucket}/")
    s3.upload_file(str(zip_path), bucket, latest_key,
                   ExtraArgs={"ContentType": "application/octet-stream"})

    # LGPL 6(a)/6(d): the source of the exact FreeTDS version we ship has to be
    # offered from the same place as the download, so it goes to R2 beside the DMG.
    version_file = DEPLOY / "freetds-version.txt"
    if version_file.exists():
        freetds_version = version_file.read_text().strip()
        tarball = ROOT / "dist" / f"freetds-{freetds_version}.tar.bz2"
        if tarball.exists():
            print(f"▸ Uploading {tarball.name} → r2://{bucket}/")
            s3.upload_file(str(tarball), bucket, tarball.name,
                           ExtraArgs={"ContentType": "application/x-bzip2"})
        elif os.environ.get("CI"):
            # Fatal under automation: a release whose licence obligation quietly
            # went unmet is not something to discover from a log nobody read.
            sys.exit(f"✗ Missing {tarball} — LGPL source offer would not be published")
        else:
            print(f"• Skipping FreeTDS source upload ({tarball.name} not built)")

    # Deltas are pure optimization on top of the full-DMG item above, which
    # already published successfully by this point — nothing from here on may
    # be allowed to fail the release itself. generate_deltas already catches
    # per-pair failures internally; this catches anything else (e.g. a
    # scripts/ helper missing outright) so a bug in delta generation degrades
    # to "no deltas this release" instead of an unpublished release.
    new_app = ROOT / "dist" / "BerryDB.app"
    try:
        delta_records = generate_deltas(s3, bucket, new_app, last, history)
    except Exception as exc:  # noqa: BLE001 - see comment above
        print(f"• Skipping deltas entirely: {exc}")
        delta_records = []
    deltas_by_version = {last["version"]: delta_records} if delta_records else {}

    appcast = build_appcast(history, download_base, deltas_by_version)
    (DEPLOY / "appcast.xml").write_text(appcast)
    print("▸ Uploading appcast.xml")
    s3.put_object(Bucket=bucket, Key="appcast.xml", Body=appcast.encode(),
                  ContentType="application/xml", CacheControl="max-age=300")

    purge_cache([
        f"{download_base.rstrip('/')}/appcast.xml",
        f"{download_base.rstrip('/')}/{last['file']}",
        f"{download_base.rstrip('/')}/{latest_key}",
    ])
    print(f"✓ Published BerryDB {last['version']}: {download_base.rstrip('/')}/{last['file']}")
    print(f"  Latest alias: {download_base.rstrip('/')}/{latest_key}")


if __name__ == "__main__":
    main()
