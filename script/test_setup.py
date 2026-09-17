"""Release builds must retain macOS verification tools after normalizing PATH."""

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
