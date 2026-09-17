#!/usr/bin/env python3
"""Preview ordering, publication barriers, and atomic feed updates."""

import base64
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("preview", Path(__file__).with_name("ci-prerelease.py"))
preview = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preview)


def record(tag, draft=False, prerelease=True):
    return {"id": 1, "tag_name": tag, "draft": draft, "prerelease": prerelease, "assets": []}


def feed(version):
    return (f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
            f'<channel><item><sparkle:version>{version}</sparkle:version></item></channel></rss>').encode()


class PreviewTest(unittest.TestCase):
    def test_retries_and_later_runs_have_increasing_numeric_versions(self):
        versions = [preview.preview_version("0.6", 1, 1), preview.preview_version("0.6", 1, 99),
                    preview.preview_version("0.6", 2, 1)]
        self.assertEqual(versions, ["0.6.1", "0.6.99", "0.6.101"])
        self.assertEqual(sorted(versions, key=lambda v: preview.release.version_tuple("v" + v)), versions)

    def test_invalid_prefix_or_run_is_rejected(self):
        for args in [("0.6-beta", 1, 1), ("01.6", 1, 1), ("0.6", 0, 1), ("0.6", 1, 100)]:
            with self.subTest(args=args), self.assertRaises(ValueError):
                preview.preview_version(*args)

    def test_old_preview_cannot_replace_newer_preview_or_stable(self):
        for prerelease in (False, True):
            with self.assertRaisesRegex(ValueError, "stale"):
                preview.check_order("v0.6.1", [record("v0.6.101", prerelease=prerelease)])

    def test_published_preview_cannot_be_overwritten(self):
        with self.assertRaisesRegex(ValueError, "already published"):
            preview.check_order("v0.6.1", [record("v0.6.1")])
        self.assertIsNone(preview.check_order("v0.6.1", [record("v0.6.1")], allow_current=True))

    def test_draft_can_be_completed(self):
        draft = record("v0.6.1", draft=True)
        self.assertEqual(preview.check_order("v0.6.1", [draft]), draft)

    def test_feed_cannot_move_backwards(self):
        with self.assertRaisesRegex(ValueError, "backwards"):
            preview.check_feed_order(feed("0.6.101"), "0.6.1")
        preview.check_feed_order(feed("0.6.1"), "0.6.101")

    def test_feed_requires_a_published_prerelease(self):
        for release in (record("v0.6.1", draft=True), record("v0.6.1", prerelease=False)):
            with patch.object(preview.release, "read_releases", return_value=[]), \
                    patch.object(preview, "api", return_value=release) as api:
                with self.assertRaisesRegex(ValueError, "published prerelease"):
                    preview.advance_feed("v0.6.1", Path("unused"))
                self.assertEqual(api.call_count, 1)

    def test_feed_update_uses_expected_previous_sha(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "appcast.xml"
            path.write_bytes(feed("0.6.101"))
            current = {"content": base64.b64encode(feed("0.6.1")).decode(), "sha": "previous-file-sha"}
            with patch.object(preview.release, "read_releases", return_value=[]), \
                    patch.object(preview, "api", side_effect=[record("v0.6.101"), {}, current, {}]) as api:
                preview.advance_feed("v0.6.101", path)
                name, method, data = api.call_args.args
                self.assertEqual((name, method), ("contents/prerelease.xml", "PUT"))
                self.assertEqual(data["sha"], "previous-file-sha")
                self.assertEqual(data["branch"], "updates")
                self.assertEqual(base64.b64decode(data["content"]), path.read_bytes())

    def test_unchanged_feed_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "appcast.xml"
            path.write_bytes(feed("0.6.1"))
            current = {"content": base64.b64encode(path.read_bytes()).decode(), "sha": "current"}
            with patch.object(preview.release, "read_releases", return_value=[]), \
                    patch.object(preview, "api", side_effect=[record("v0.6.1"), {}, current]) as api:
                preview.advance_feed("v0.6.1", path)
                self.assertEqual(api.call_count, 3)

    def test_fork_and_branch_context_are_restricted(self):
        for repo, ref in [("someone/winmux", "refs/heads/main"),
                          (preview.REPOSITORY, "refs/pull/1/merge"),
                          (preview.REPOSITORY, "refs/heads/updates")]:
            with patch.dict("os.environ", {"GITHUB_REPOSITORY": repo, "GITHUB_REF": ref}):
                with self.assertRaises(ValueError):
                    preview.check_context()

    def test_upload_verification_failure_never_publishes_or_advances_feed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "archive.zip"
            path.write_bytes(b"signed archive")
            draft = record("v0.6.1", draft=True)
            with patch.dict("os.environ", {"RELEASE_TAG": "v0.6.1", "RELEASE_DIR": directory}), \
                    patch.object(preview, "check_context"), patch.object(preview.release, "check_tag"), \
                    patch.object(preview.release, "release_assets", return_value=[path]), \
                    patch.object(preview.appcast, "validate_appcast"), \
                    patch.object(preview.release, "read_releases", return_value=[draft]), \
                    patch.object(preview, "api", return_value=draft), \
                    patch.object(preview.release, "run") as run, \
                    patch.object(preview, "advance_feed") as advance:
                with self.assertRaisesRegex(ValueError, "exactly match"):
                    preview.publish()
                self.assertFalse(any("edit" in call.args for call in run.call_args_list))
                advance.assert_not_called()


if __name__ == "__main__":
    unittest.main()
