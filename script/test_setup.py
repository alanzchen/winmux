"""Release builds must keep macOS verification tools and a usable SDK after setup.sh."""

import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


class SetupTest(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin", "macOS release tool")
    def test_normalized_path_keeps_gatekeeper_available(self):
        setup = Path(__file__).with_name("setup.sh").resolve()
        environment = dict(os.environ, PATH="/usr/bin:/bin")
        environment.pop("NUKE_PATH", None)
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                ["/bin/bash", "-c", f"source {shlex.quote(str(setup))}; command -v spctl"],
                cwd=directory, env=environment, text=True, capture_output=True, check=True,
            )
        self.assertEqual(result.stdout.strip(), "/usr/sbin/spctl")

    @unittest.skipUnless(sys.platform == "darwin", "macOS release tool")
    def test_builds_use_the_selected_developer_sdk_unless_one_is_chosen(self):
        selected_sdk = subprocess.run(
            ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"],
            text=True, capture_output=True, check=True,
        ).stdout.strip()
        self.assertEqual(exported_sdkroot(), selected_sdk)
        self.assertEqual(exported_sdkroot(SDKROOT="/chosen/MacOSX.sdk"), "/chosen/MacOSX.sdk")

    @unittest.skipUnless(sys.platform == "darwin", "macOS release tool")
    def test_missing_sdk_leaves_sdkroot_unset(self):
        broken = {"DEVELOPER_DIR": "/nonexistent-developer-dir"}
        if subprocess.run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"],
                          env=dict(os.environ, **broken), capture_output=True).returncode == 0:
            self.skipTest("xcrun still resolves an SDK")
        self.assertEqual(exported_sdkroot(**broken), "")


def exported_sdkroot(**overrides):
    """SDKROOT as a child process (swiftly) sees it after sourcing setup.sh."""
    setup = Path(__file__).with_name("setup.sh").resolve()
    environment = dict(os.environ, PATH="/usr/bin:/bin")
    environment.pop("NUKE_PATH", None)
    environment.pop("SDKROOT", None)
    environment.update(overrides)
    with tempfile.TemporaryDirectory() as directory:
        result = subprocess.run(
            ["/bin/bash", "-c", f"source {shlex.quote(str(setup))}; /usr/bin/printenv SDKROOT || true"],
            cwd=directory, env=environment, text=True, capture_output=True, check=True,
        )
    return result.stdout.strip()
