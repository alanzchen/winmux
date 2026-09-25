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
    def test_local_and_hosted_builds_share_increasing_numeric_versions(self):
        self.assertEqual(preview.preview_version("0.6", []), "0.6.1")
        self.assertEqual(preview.preview_version("0.6", ["v0.6.1", "v0.6.301", "v0.5.9", "unrelated"]), "0.6.302")
        self.assertEqual(preview.preview_version("0.7", ["v0.6.302"]), "0.7.1")

    def test_invalid_prefix_is_rejected(self):
        for prefix in ["0.6-beta", "01.6", "0.6.1", "0.6\n"]:
            with self.subTest(prefix=prefix), self.assertRaises(ValueError):
                preview.preview_version(prefix, [])

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

    def test_detached_release_worktree_names_its_integration_branch(self):
        with patch.object(preview.release, "run", side_effect=["", "commit"]), \
                patch.dict("os.environ", {"RELEASE_BRANCH": "main"}):
            self.assertEqual(preview.check_context(local=True), "commit")
        with patch.object(preview.release, "run", return_value=""), patch.dict("os.environ", {"RELEASE_BRANCH": "updates"}):
            with self.assertRaisesRegex(ValueError, "integration branch"):
                preview.check_context(local=True)
        # A checked-out feature branch can't borrow the release branch name.
        with patch.object(preview.release, "run", return_value="feature"), patch.dict("os.environ", {"RELEASE_BRANCH": "main"}):
            with self.assertRaisesRegex(ValueError, "integration branch"):
                preview.check_context(local=True)

    def test_upload_verification_failure_never_publishes_or_advances_feed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "archive.zip"
            path.write_bytes(b"signed archive")
            draft = record("v0.6.1", draft=True)
            with patch.dict("os.environ", {"RELEASE_TAG": "v0.6.1", "RELEASE_DIR": directory}), \
                    patch.object(preview, "check_context"), patch.object(preview.release, "check_tag"), \
                    patch.object(preview, "published_for_commit", return_value=None), \
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

    def test_hosted_build_skips_a_commit_already_published_locally(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = Path(directory) / "env"
            with patch.dict("os.environ", {"GITHUB_ENV": str(environment)}), \
                    patch.object(preview, "check_context", return_value="commit"), \
                    patch.object(preview, "published_for_commit", return_value=record("v0.6.302")), \
                    patch.object(preview, "repair_published_feed") as repair, \
                    patch.object(preview, "api") as api:
                self.assertEqual(preview.prepare(), ("v0.6.302", True))
                self.assertIn("SKIP_RELEASE=true", environment.read_text())
                repair.assert_called_once()
                api.assert_not_called()

    def test_new_draft_uses_creation_response_when_listing_is_stale(self):
        draft = record("v0.6.302", draft=True)
        with patch.dict("os.environ", {"RELEASE_TAG": "v0.6.302"}), \
                patch.object(preview, "check_context", return_value="commit"), \
                patch.object(preview, "published_for_commit", return_value=None), \
                patch.object(preview.release, "check_tag"), \
                patch.object(preview.release, "release_assets", return_value=[]), \
                patch.object(preview.appcast, "validate_appcast"), \
                patch.object(preview.release, "read_releases", return_value=[]), \
                patch.object(preview, "api", return_value=draft) as api, \
                patch.object(preview.release, "verify_uploaded_assets"), \
                patch.object(preview.release, "run"), patch.object(preview, "advance_feed"):
            self.assertEqual(preview.publish(local=True), "v0.6.302")
            self.assertEqual(api.call_args_list[0].args[:2], ("releases", "POST"))

    def test_commit_lookup_ignores_noncanonical_release_tags(self):
        tags = ["v0.6.302", "vexperimental"]
        refs = [{"ref": f"refs/tags/{tag}", "object": {"type": "commit", "sha": "commit"}} for tag in tags]
        with patch.object(preview, "api", return_value=refs), \
                patch.object(preview.release, "read_releases", return_value=[record(tag) for tag in tags]):
            self.assertEqual(preview.published_for_commit("commit")["tag_name"], "v0.6.302")

    def test_losing_build_uses_existing_release_and_repairs_feed(self):
        with patch.object(preview, "check_context", return_value="commit"), \
                patch.object(preview, "published_for_commit", return_value=record("v0.6.302")), \
                patch.object(preview, "repair_published_feed") as repair, \
                patch.object(preview.release, "release_assets") as assets:
            self.assertEqual(preview.publish(local=True), "v0.6.302")
            repair.assert_called_once()
            assets.assert_not_called()

    def test_atomic_tag_collision_allocates_another_version(self):
        refs = lambda tag: [{"ref": f"refs/tags/{tag}"}]
        with patch.object(preview, "check_context", return_value="commit"), \
                patch.object(preview, "published_for_commit", return_value=None), \
                patch.object(preview.release, "read_releases", return_value=[]), \
                patch.object(preview.release, "check_tag"), patch.object(preview.release, "run"), \
                patch.object(Path, "read_text", return_value="0.6"), \
                patch.object(preview, "api", side_effect=[
                    refs("v0.6.301"), ValueError("already exists"), {"ref": "refs/tags/v0.6.302"},
                    refs("v0.6.302"), {"ref": "refs/tags/v0.6.303"},
                ]):
            self.assertEqual(preview.prepare(local=True), ("v0.6.303", False))


if __name__ == "__main__":
    unittest.main()
