"""Packaging regressions for case-insensitive volumes and standalone CLI signing."""

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "verify_bundle_executables", Path(__file__).with_name("verify-bundle-executables.py")
)
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class BundleExecutablesTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.app = Path(self.directory.name) / "WinMux.app"
        self.gui = self.app / "Contents" / "MacOS" / "WinMux"
        self.cli = self.app / "Contents" / "Helpers" / "winmux"
        self.gui.parent.mkdir(parents=True)
        self.cli.parent.mkdir(parents=True)
        self.gui.write_bytes(b"GUI executable")
        self.cli.write_bytes(b"standalone CLI executable")
        self.gui.chmod(0o755)
        self.cli.chmod(0o755)

    def test_gui_and_helper_have_distinct_case_insensitive_paths_and_contents(self):
        gui, cli = verifier.distinct_executables(self.app)
        self.assertNotEqual(str(gui).casefold(), str(cli).casefold())
        self.assertNotEqual(gui.read_bytes(), cli.read_bytes())

    def test_case_insensitive_alias_cannot_be_used_as_helper(self):
        # Default APFS resolves this case variant to the GUI. A hard link gives
        # the same alias identity on case-sensitive test hosts.
        legacy_cli = self.gui.with_name("winmux")
        if not legacy_cli.exists():
            os.link(self.gui, legacy_cli)
        self.assertTrue(self.gui.samefile(legacy_cli))
        self.cli.unlink()
        self.cli.symlink_to(legacy_cli)
        with self.assertRaisesRegex(ValueError, "distinct executables"):
            verifier.distinct_executables(self.app)

    def test_independent_copy_of_gui_is_not_a_cli(self):
        shutil.copy2(self.gui, self.cli)
        self.assertFalse(self.gui.samefile(self.cli))
        with self.assertRaisesRegex(ValueError, "distinct executables"):
            verifier.distinct_executables(self.app)

    def test_missing_or_nonexecutable_helper_is_rejected(self):
        self.cli.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "Missing executable"):
            verifier.distinct_executables(self.app)
        self.cli.unlink()
        with self.assertRaisesRegex(ValueError, "Missing executable"):
            verifier.distinct_executables(self.app)

    def test_cli_signature_is_checked_after_copying_outside_bundle(self):
        copies = []

        def codesign(command, check):
            copied = Path(command[-1])
            self.assertNotIn(self.app, copied.parents)
            self.assertEqual(copied.read_bytes(), self.cli.read_bytes())
            self.assertTrue(os.access(copied, os.X_OK))
            self.assertIn("--verify", command)
            self.assertTrue(check)
            copies.append(copied)

        with patch.object(verifier.subprocess, "run", side_effect=codesign):
            verifier.verify_bundle(self.app)
        self.assertEqual(len(copies), 1)
        self.assertFalse(copies[0].exists())

    def test_standalone_signature_failure_prevents_success(self):
        error = subprocess.CalledProcessError(1, "codesign")
        with patch.object(verifier.subprocess, "run", side_effect=error):
            with self.assertRaises(subprocess.CalledProcessError):
                verifier.verify_bundle(self.app)

    @unittest.skipUnless(sys.platform == "darwin", "Requires macOS code signature verification")
    def test_copied_native_cli_keeps_valid_standalone_signature(self):
        # Existing signed OS tools provide Mach-O fixtures without building or
        # creating a signing identity. The GUI fixture is deliberately different.
        shutil.copyfile("/usr/bin/false", self.gui)
        shutil.copyfile("/usr/bin/true", self.cli)
        verifier.verify_bundle(self.app)


if __name__ == "__main__":
    unittest.main()
