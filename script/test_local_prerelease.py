"""Local release source integrity."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("local", Path(__file__).with_name("local-prerelease.py"))
local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local)


class LocalPreviewTest(unittest.TestCase):
    def test_progress_markers_appear_only_for_script_ship(self):
        import contextlib, io, os
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("WINMUX_SHIP_TOKEN", None)
            with contextlib.redirect_stdout(io.StringIO()) as output:
                local.phase("tests")
            self.assertEqual(output.getvalue(), "")
            os.environ["WINMUX_SHIP_TOKEN"] = "t0k3n"
            with contextlib.redirect_stdout(io.StringIO()) as output:
                local.phase("tests")
                local.marker("url", "https://example/v1")
            self.assertEqual(output.getvalue(), "::phase:t0k3n:: tests\n::url:t0k3n:: https://example/v1\n")

    def test_changed_head_cannot_be_published(self):
        with patch.object(local.preview.release, "run", return_value="other"):
            with self.assertRaisesRegex(ValueError, "HEAD changed"):
                local.verify_source("commit", {})

    def test_changed_source_cannot_be_published(self):
        with patch.object(local.preview.release, "run", side_effect=["commit", "Sources/AppBundle/App.swift"]):
            with self.assertRaisesRegex(ValueError, "Source changed"):
                local.verify_source("commit", {})

    def test_untracked_source_cannot_enter_a_tagged_build(self):
        with patch.object(local.preview.release, "run", side_effect=["commit", "", "Sources/AppBundle/New.swift"]):
            with self.assertRaisesRegex(ValueError, "Untracked source"):
                local.verify_source("commit", {})

    def test_expected_metadata_is_required(self):
        with tempfile.TemporaryDirectory() as directory:
            metadata = Path(directory) / "version.swift"
            metadata.write_bytes(b"another build")
            with patch.object(local.preview.release, "run", side_effect=["commit", "", ""]):
                with self.assertRaisesRegex(ValueError, "metadata changed"):
                    local.verify_source("commit", {metadata: b"our build"})
            metadata.write_bytes(b"our build")
            with patch.object(local.preview.release, "run", side_effect=["commit", "", ""]):
                local.verify_source("commit", {metadata: b"our build"})
