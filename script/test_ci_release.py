#!/usr/bin/env python3
"""Release publication invariants; no credentials, native signing, or network needed."""

import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("ci_release", Path(__file__).with_name("ci-release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def record(tag, draft=False, prerelease=False):
    return {"tag_name": tag, "draft": draft, "prerelease": prerelease, "assets": [], "id": 1}


class ReleaseTest(unittest.TestCase):
    def test_only_stable_canonical_tags_are_accepted(self):
        self.assertEqual(release.version_tuple("v1.20.3"), (1, 20, 3))
        for tag in ["1.2.3", "v1.2", "v01.2.3", "v1.2.3-beta", "v1.2.3\n", "v1.2.3;echo bad"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.version_tuple(tag)

    def test_published_assets_cannot_be_replaced(self):
        with self.assertRaisesRegex(ValueError, "already published"):
            release.check_release_order("v1.2.3", [record("v1.2.3")])

    def test_older_version_cannot_replace_latest_feed(self):
        with self.assertRaisesRegex(ValueError, "newer"):
            release.check_release_order("v1.2.9", [record("v1.10.0")])

    def test_incomplete_draft_can_be_retried(self):
        draft = record("v1.2.3", draft=True)
        self.assertEqual(release.check_release_order("v1.2.3", [draft, record("v1.2.2")]), draft)

    def test_prerelease_does_not_block_stable_release(self):
        self.assertIsNone(release.check_release_order("v1.2.3", [record("v2.0.0-beta", prerelease=True)]))

    def test_dispatch_must_run_on_matching_tag_ref(self):
        with patch.dict("os.environ", {"GITHUB_ACTIONS": "true", "GITHUB_REF": "refs/heads/main"}):
            with self.assertRaisesRegex(ValueError, "same tag ref"):
                release.check_tag("v1.2.3", "alanzchen/winmux")

    def test_annotated_tag_resolves_to_its_commit(self):
        with patch.dict("os.environ", {"GITHUB_ACTIONS": "false"}), patch.object(release, "run", side_effect=[
            "commit", "commit", "object\trefs/tags/v1.2.3\ncommit\trefs/tags/v1.2.3^{}",
        ]):
            release.check_tag("v1.2.3", "alanzchen/winmux")

    def test_remote_tag_cannot_move_after_checkout(self):
        with patch.dict("os.environ", {"GITHUB_ACTIONS": "false"}), patch.object(release, "run", side_effect=[
            "commit", "commit", "changed\trefs/tags/v1.2.3",
        ]):
            with self.assertRaisesRegex(ValueError, "changed"):
                release.check_tag("v1.2.3", "alanzchen/winmux")

    def test_missing_distribution_asset_fails_before_publishing(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "Missing"):
                release.release_assets("v1.2.3", directory)

    def test_uploaded_asset_checksums_must_match(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "archive.zip"
            path.write_bytes(b"signed archive")
            uploaded = {"name": path.name, "size": path.stat().st_size, "state": "uploaded",
                        "digest": "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()}
            release.verify_uploaded_assets([path], [uploaded])
            uploaded["digest"] = "sha256:wrong"
            with self.assertRaisesRegex(ValueError, "checksum"):
                release.verify_uploaded_assets([path], [uploaded])

    def test_extra_draft_assets_prevent_publication(self):
        with self.assertRaisesRegex(ValueError, "exactly match"):
            release.verify_uploaded_assets([], [{"name": "unexpected.zip"}])

    def test_failed_upload_verification_never_publishes_the_draft(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "archive.zip"
            path.write_bytes(b"signed archive")
            draft = record("v1.2.3", draft=True)
            uploaded = dict(draft, assets=[{"name": path.name, "state": "uploaded",
                                           "size": path.stat().st_size, "digest": "sha256:wrong"}])
            with patch.object(release, "release_assets", return_value=[path]), \
                    patch.object(release, "check_tag"), \
                    patch.object(release, "read_releases", return_value=[draft]), \
                    patch.object(release, "run", side_effect=["", release.json.dumps(uploaded)]) as command:
                with self.assertRaisesRegex(ValueError, "checksum"):
                    release.publish("v1.2.3", "alanzchen/winmux", directory)
                self.assertFalse(any("edit" in call.args for call in command.call_args_list))


if __name__ == "__main__":
    unittest.main()
