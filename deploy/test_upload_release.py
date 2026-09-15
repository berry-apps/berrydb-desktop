#!/usr/bin/env python3
"""Tests for record_release, build_appcast and generate_deltas in
upload-release.py. Standard library only — no pytest, no boto3, no network.
Run: python3 deploy/test_upload_release.py

Why this exists: on a disposable CI runner the tracked deploy/releases.json is
whatever main holds, so merging into it and discarding the result drops every
intermediate version from the appcast. That failure is silent — the appcast is
still valid XML, just missing releases — so it needs a test rather than a review.

The generate_deltas tests stub scripts/extract-app-from-dmg.sh,
scripts/build-delta.sh and scripts/sign-update.sh (via a temp scripts_dir) the
same way scripts/test-sign-update.sh stubs sign_update — no real DMG mounting,
no real BinaryDelta, no real Sparkle key. What those scripts actually do is
covered by their own shell tests (scripts/test-extract-app-from-dmg.sh,
scripts/test-build-delta.sh, scripts/test-sign-update.sh); this file only
checks that generate_deltas calls them correctly and degrades safely when they
fail.
"""
import importlib.util
import json
import pathlib
import stat
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent

spec = importlib.util.spec_from_file_location("upload_release", HERE / "upload-release.py")
upload_release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upload_release)

FAILURES = []


def check(name, condition, detail=""):
    if condition:
        print(f"ok   - {name}")
    else:
        print(f"FAIL - {name}\n       {detail}")
        FAILURES.append(name)


class FakeS3:
    """Stands in for the boto3 S3 client, with only the calls we make."""

    class _NoSuchKey(Exception):
        pass

    def __init__(self, objects=None):
        self.objects = dict(objects or {})
        self.exceptions = type("exceptions", (), {"NoSuchKey": FakeS3._NoSuchKey})
        self.uploaded = {}  # Key -> local path, for assertions
        self.downloaded = []  # Keys passed to download_file, in call order

    def get_object(self, Bucket, Key):
        if Key not in self.objects:
            raise FakeS3._NoSuchKey(Key)
        body = self.objects[Key]
        return {"Body": type("Body", (), {"read": staticmethod(lambda: body)})}

    def put_object(self, Bucket, Key, Body, **kwargs):
        self.objects[Key] = Body if isinstance(Body, bytes) else Body.encode()

    def download_file(self, Bucket, Key, Filename):
        self.downloaded.append(Key)
        if Key not in self.objects:
            raise FakeS3._NoSuchKey(Key)
        pathlib.Path(Filename).write_bytes(self.objects[Key])

    def upload_file(self, Filename, Bucket, Key, **kwargs):
        self.objects[Key] = pathlib.Path(Filename).read_bytes()
        self.uploaded[Key] = Filename


def with_deploy_dir(last, tracked_history):
    """Point the module at a temp deploy/ holding these two files."""
    tmp = tempfile.mkdtemp()
    d = pathlib.Path(tmp)
    (d / "last-release.json").write_text(json.dumps(last))
    if tracked_history is not None:
        (d / "releases.json").write_text(json.dumps(tracked_history))
    upload_release.DEPLOY = d
    return d


V103 = {"version": "1.0.3", "file": "BerryDB-1.0.3.dmg", "path": "dist/BerryDB-1.0.3.dmg"}
V102 = {"version": "1.0.2", "file": "BerryDB-1.0.2.dmg", "path": "dist/BerryDB-1.0.2.dmg"}
V101 = {"version": "1.0.1", "file": "BerryDB-1.0.1.dmg", "path": "dist/BerryDB-1.0.1.dmg"}

# 1. R2 already holds a history: it is the source, and the merged result goes back.
with_deploy_dir(V103, tracked_history=[V101])
s3 = FakeS3({"releases.json": json.dumps([V102, V101]).encode()})
result = upload_release.record_release(s3, "bucket")
versions = [r["version"] for r in result["history"]]
check("R2 history is used, not the tracked file",
      versions == ["1.0.3", "1.0.2", "1.0.1"], f"got {versions}")
check("merged history is written back to R2",
      "releases.json" in s3.objects, "put_object was never called")
written = [r["version"] for r in json.loads(s3.objects["releases.json"])]
check("what is written back matches what is returned",
      written == versions, f"written {written} vs returned {versions}")

# 2. First run: no R2 object yet, so the tracked file seeds the history.
#    Without this the four already-published versions vanish from the appcast.
with_deploy_dir(V103, tracked_history=[V102, V101])
s3 = FakeS3()
result = upload_release.record_release(s3, "bucket")
versions = [r["version"] for r in result["history"]]
check("missing R2 object falls back to the tracked file",
      versions == ["1.0.3", "1.0.2", "1.0.1"], f"got {versions}")

# 3. Re-releasing a version replaces it rather than duplicating it.
with_deploy_dir(V103, tracked_history=None)
s3 = FakeS3({"releases.json": json.dumps([V103, V102]).encode()})
result = upload_release.record_release(s3, "bucket")
versions = [r["version"] for r in result["history"]]
check("a repeated version is deduplicated",
      versions == ["1.0.3", "1.0.2"], f"got {versions}")

# 4. Neither source exists: the new release is still the whole history.
with_deploy_dir(V103, tracked_history=None)
s3 = FakeS3()
result = upload_release.record_release(s3, "bucket")
check("no history anywhere still yields the new release",
      [r["version"] for r in result["history"]] == ["1.0.3"],
      f"got {result['history']}")

# 5. `last` is the entry just read, unchanged.
check("last is the new release", result["last"]["version"] == "1.0.3",
      f"got {result['last']}")


# ---- build_appcast: sparkle:deltaFrom items --------------------------------

APPCAST_HISTORY = [
    {"version": "1.0.4", "file": "BerryDB-1.0.4.dmg", "length": 100, "edSignature": "sigNEW",
     "pubDate": "Mon, 01 Jan 2026 00:00:00 +0000"},
    {"version": "1.0.3", "file": "BerryDB-1.0.3.dmg", "length": 90, "edSignature": "sigOLD",
     "pubDate": "Sun, 31 Dec 2025 00:00:00 +0000"},
]

# 6. No deltas passed at all (the pre-existing call signature): unchanged output,
#    no stray <sparkle:deltas> anywhere. Guards the plain-DMG path this project
#    has shipped since before deltas existed.
appcast = upload_release.build_appcast(APPCAST_HISTORY, "https://dl.example.com")
check("no deltas arg: no sparkle:deltas element appears",
      "sparkle:deltas" not in appcast, appcast)

# 7. Deltas for the newest version only: its item gets a <sparkle:deltas> block
#    with sparkle:deltaFrom/url/length/edSignature; the older item is untouched.
deltas_by_version = {
    "1.0.4": [
        {"deltaFrom": "1.0.3", "file": "BerryDB-1.0.3-1.0.4.delta", "length": 12345, "edSignature": "sigDELTA"},
    ]
}
appcast = upload_release.build_appcast(APPCAST_HISTORY, "https://dl.example.com", deltas_by_version)
check("delta enclosure carries sparkle:deltaFrom",
      'sparkle:deltaFrom="1.0.3"' in appcast, appcast)
check("delta enclosure points at the delta file under the download base",
      'url="https://dl.example.com/BerryDB-1.0.3-1.0.4.delta"' in appcast, appcast)
check("delta enclosure carries its own length and signature",
      'length="12345"' in appcast and 'sparkle:edSignature="sigDELTA"' in appcast, appcast)
# The older item (1.0.3) has no deltas of its own in this run — only ONE
# <sparkle:deltas> block should exist in the whole feed.
check("only the version with deltas gets a <sparkle:deltas> block",
      appcast.count("<sparkle:deltas>") == 1, appcast)


# ---- generate_deltas --------------------------------------------------------

def make_stub_scripts(tmp, *, extract_fails_for=(), build_delta_rc=0, sign_output="SIGDUMMY"):
    """A throwaway scripts/ dir with stand-ins for the three shell helpers
    generate_deltas shells out to. Mirrors how scripts/test-sign-update.sh
    stubs sign_update — no real DMG mounting, no real BinaryDelta binary.
    """
    d = pathlib.Path(tmp) / "scripts"
    d.mkdir(parents=True, exist_ok=True)

    fail_cases = "\n".join(f'  *{needle}*) echo "stub: forced failure" >&2; exit 1 ;;' for needle in extract_fails_for)
    (d / "extract-app-from-dmg.sh").write_text(
        "#!/bin/sh\n"
        "case \"$1\" in\n"
        f"{fail_cases}\n"
        "esac\n"
        "mkdir -p \"$2\"\n"
    )

    if build_delta_rc == 0:
        (d / "build-delta.sh").write_text("#!/bin/sh\necho fake-delta-bytes > \"$3\"\n")
    else:
        (d / "build-delta.sh").write_text(
            f"#!/bin/sh\necho 'stub: BinaryDelta unavailable or failed' >&2\nexit {build_delta_rc}\n"
        )

    (d / "sign-update.sh").write_text(f"#!/bin/sh\nprintf '%s' '{sign_output}'\n")

    for name in ("extract-app-from-dmg.sh", "build-delta.sh", "sign-update.sh"):
        path = d / name
        path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return d


def make_new_app(tmp):
    app = pathlib.Path(tmp) / "New.app"
    app.mkdir(parents=True, exist_ok=True)
    return app


LAST = {"version": "1.0.6", "file": "BerryDB-1.0.6.dmg", "path": "dist/BerryDB-1.0.6.dmg"}
# Ordered newest-first, as record_release produces. 1.0.4 is a .zip (an old
# pre-DMG release) and must never be attempted as a delta source. 1.0.0 sits
# past the DELTA_WINDOW (5 candidates after `last`) and must never be attempted
# either.
FULL_HISTORY_AFTER_LAST = [
    {"version": "1.0.5", "file": "BerryDB-1.0.5.dmg", "path": "dist/BerryDB-1.0.5.dmg"},
    {"version": "1.0.4", "file": "BerryDB-1.0.4.zip", "path": "dist/BerryDB-1.0.4.zip"},
    {"version": "1.0.3", "file": "BerryDB-1.0.3.dmg", "path": "dist/BerryDB-1.0.3.dmg"},
    {"version": "1.0.2", "file": "BerryDB-1.0.2.dmg", "path": "dist/BerryDB-1.0.2.dmg"},
    {"version": "1.0.1", "file": "BerryDB-1.0.1.dmg", "path": "dist/BerryDB-1.0.1.dmg"},
    {"version": "1.0.0", "file": "BerryDB-1.0.0.dmg", "path": "dist/BerryDB-1.0.0.dmg"},
]
FULL_HISTORY = [LAST] + FULL_HISTORY_AFTER_LAST

check("DELTA_WINDOW is a small, documented, bounded number",
      isinstance(upload_release.DELTA_WINDOW, int) and 0 < upload_release.DELTA_WINDOW <= 10,
      f"got {upload_release.DELTA_WINDOW!r}")

# 8. new_app missing entirely (e.g. running upload-release.py without a fresh
#    release.sh run, or in a test): skip everything, no exception, no S3 calls.
tmp = tempfile.mkdtemp()
scripts_dir = make_stub_scripts(tmp)
s3 = FakeS3()
result = upload_release.generate_deltas(
    s3, "bucket", pathlib.Path(tmp) / "does-not-exist.app", LAST, FULL_HISTORY, scripts_dir=scripts_dir)
check("missing new .app: no deltas, no crash", result == [], f"got {result}")
check("missing new .app: never touches S3", s3.downloaded == [] and s3.uploaded == {}, "S3 was touched")

# 9. Happy path + the three skip rules at once: 1.0.4 (.zip) is skipped without
#    a download attempt, 1.0.0 is outside DELTA_WINDOW and never attempted, and
#    the three eligible .dmg versions (1.0.5, 1.0.3, 1.0.2, 1.0.1 -- four, but
#    DELTA_WINDOW=5 counts 1.0.4 among the 5 candidates even though it's
#    skipped for being a .zip) each produce a signed, uploaded delta.
tmp = tempfile.mkdtemp()
scripts_dir = make_stub_scripts(tmp)
new_app = make_new_app(tmp)
s3 = FakeS3({
    "BerryDB-1.0.5.dmg": b"old-dmg-1.0.5",
    "BerryDB-1.0.3.dmg": b"old-dmg-1.0.3",
    "BerryDB-1.0.2.dmg": b"old-dmg-1.0.2",
    "BerryDB-1.0.1.dmg": b"old-dmg-1.0.1",
    "BerryDB-1.0.0.dmg": b"old-dmg-1.0.0",
})
result = upload_release.generate_deltas(s3, "bucket", new_app, LAST, FULL_HISTORY, scripts_dir=scripts_dir)
result_versions = sorted(d["deltaFrom"] for d in result)
check("builds a delta from every eligible .dmg version inside the window",
      result_versions == ["1.0.1", "1.0.2", "1.0.3", "1.0.5"], f"got {result_versions}")
check("skips the .zip release without downloading it",
      "BerryDB-1.0.4.zip" not in s3.downloaded, f"downloaded: {s3.downloaded}")
check("never attempts a version outside DELTA_WINDOW",
      "BerryDB-1.0.0.dmg" not in s3.downloaded, f"downloaded: {s3.downloaded}")
check("every produced delta carries the real EdDSA signature from sign-update.sh",
      all(d["edSignature"] == "SIGDUMMY" for d in result), f"got {result}")
check("every produced delta was uploaded to R2",
      all(d["file"] in s3.uploaded for d in result), f"uploaded keys: {list(s3.uploaded)}")

# 10. One candidate's extraction fails: that one is skipped, the rest still
#     succeed, and the release-breaking exception never escapes.
tmp = tempfile.mkdtemp()
scripts_dir = make_stub_scripts(tmp, extract_fails_for=["1.0.2"])
new_app = make_new_app(tmp)
s3 = FakeS3({
    "BerryDB-1.0.5.dmg": b"x", "BerryDB-1.0.3.dmg": b"x",
    "BerryDB-1.0.2.dmg": b"x", "BerryDB-1.0.1.dmg": b"x", "BerryDB-1.0.0.dmg": b"x",
})
result = upload_release.generate_deltas(s3, "bucket", new_app, LAST, FULL_HISTORY, scripts_dir=scripts_dir)
result_versions = sorted(d["deltaFrom"] for d in result)
check("a single failed extraction is skipped, others still succeed",
      result_versions == ["1.0.1", "1.0.3", "1.0.5"], f"got {result_versions}")

# 11. BinaryDelta itself is unavailable (exit code 2, per build-delta.sh):
#     every remaining candidate is abandoned rather than retried one-by-one --
#     the tool being missing is a global fact, not a per-pair one.
tmp = tempfile.mkdtemp()
scripts_dir = make_stub_scripts(tmp, build_delta_rc=2)
new_app = make_new_app(tmp)
s3 = FakeS3({"BerryDB-1.0.5.dmg": b"x", "BerryDB-1.0.3.dmg": b"x"})
result = upload_release.generate_deltas(s3, "bucket", new_app, LAST, FULL_HISTORY, scripts_dir=scripts_dir)
check("BinaryDelta unavailable: no deltas produced", result == [], f"got {result}")
check("BinaryDelta unavailable: abandons the whole run after the first failure, doesn't retry every candidate",
      len(s3.downloaded) <= 1, f"downloaded: {s3.downloaded}")

# 12. sign-update.sh produces an empty signature: an unsigned delta is as
#     unusable as an unsigned DMG (release.sh refuses those under CI), so it
#     must not appear in the appcast even though BinaryDelta itself succeeded.
tmp = tempfile.mkdtemp()
scripts_dir = make_stub_scripts(tmp, sign_output="")
new_app = make_new_app(tmp)
s3 = FakeS3({"BerryDB-1.0.5.dmg": b"x"})
result = upload_release.generate_deltas(
    s3, "bucket", new_app, LAST, [LAST, FULL_HISTORY_AFTER_LAST[0]], scripts_dir=scripts_dir)
check("an empty EdDSA signature is never published as a delta", result == [], f"got {result}")

print()
if FAILURES:
    print(f"{len(FAILURES)} test(s) failed.")
    sys.exit(1)
print("All upload-release tests passed.")
