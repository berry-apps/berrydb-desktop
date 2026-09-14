#!/usr/bin/env python3
"""Tests for record_release in upload-release.py. Standard library only — no
pytest, no boto3, no network. Run: python3 deploy/test_upload_release.py

Why this exists: on a disposable CI runner the tracked deploy/releases.json is
whatever main holds, so merging into it and discarding the result drops every
intermediate version from the appcast. That failure is silent — the appcast is
still valid XML, just missing releases — so it needs a test rather than a review.
"""
import importlib.util
import json
import pathlib
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
    """Stands in for the boto3 S3 client, with only the two calls we make."""

    class _NoSuchKey(Exception):
        pass

    def __init__(self, objects=None):
        self.objects = dict(objects or {})
        self.exceptions = type("exceptions", (), {"NoSuchKey": FakeS3._NoSuchKey})

    def get_object(self, Bucket, Key):
        if Key not in self.objects:
            raise FakeS3._NoSuchKey(Key)
        body = self.objects[Key]
        return {"Body": type("Body", (), {"read": staticmethod(lambda: body)})}

    def put_object(self, Bucket, Key, Body, **kwargs):
        self.objects[Key] = Body if isinstance(Body, bytes) else Body.encode()


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

print()
if FAILURES:
    print(f"{len(FAILURES)} test(s) failed.")
    sys.exit(1)
print("All upload-release tests passed.")
