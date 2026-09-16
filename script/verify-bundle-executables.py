#!/usr/bin/env python3
"""Reject GUI/CLI collisions and verify that the bundled CLI is standalone code."""

import filecmp
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def distinct_executables(app):
    gui = app / "Contents" / "MacOS" / "WinMux"
    cli = app / "Contents" / "Helpers" / "winmux"
    for executable in (gui, cli):
        if not executable.is_file() or not os.access(executable, os.X_OK):
            raise ValueError(f"Missing executable: {executable}")
    if gui.samefile(cli) or filecmp.cmp(gui, cli, shallow=False):
        raise ValueError("WinMux GUI and bundled CLI must be distinct executables")
    return gui, cli


def verify_bundle(app):
    _, cli = distinct_executables(app)
    # A GUI executable can verify inside its signed bundle but fail when copied
    # out because its signature requires the bundle's Info.plist. Test the CLI in
    # isolation before notarizing or distributing it.
    with tempfile.TemporaryDirectory(prefix="winmux-cli-verification-") as directory:
        standalone = Path(directory) / "winmux"
        shutil.copy2(cli, standalone)
        subprocess.run(
            ["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(standalone)],
            check=True,
        )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: verify-bundle-executables.py /path/to/WinMux.app")
    try:
        verify_bundle(Path(sys.argv[1]))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
