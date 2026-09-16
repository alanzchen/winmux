"""Verify that installed CLI launchers follow app updates without altering calls."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


LAUNCHER = Path(__file__).with_name("winmux-launcher.sh")


class WinMuxLauncherTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.pair = self.root / "release with spaces"
        self.launcher = self.pair / "bin" / "winmux"
        self.launcher.parent.mkdir(parents=True)
        shutil.copyfile(LAUNCHER, self.launcher)
        self.launcher.chmod(0o755)
        self.config = self.launcher.with_name("winmux-app-path")
        self.environment = os.environ.copy()
        self.environment.pop("WINMUX_APP_PATH", None)

    def app(self, path, version, exit_code=0):
        gui = path / "Contents" / "MacOS" / "WinMux"
        gui.parent.mkdir(parents=True)
        gui.write_text("#!/bin/sh\nprintf '%s\\n' 'GUI must not run as CLI' >&2\nexit 97\n")
        gui.chmod(0o755)
        executable = path / "Contents" / "Helpers" / "winmux"
        executable.parent.mkdir(parents=True)
        executable.write_text(
            "#!/bin/sh\n"
            f"printf '%s\\n' '{version}'\n"
            "for argument do printf '%s\\0' \"$argument\"; done\n"
            "printf '\\n'\n"
            "cat\n"
            f"exit {exit_code}\n"
        )
        executable.chmod(0o755)
        return path

    def invoke(self, *arguments, stdin=b"", launcher=None):
        return subprocess.run(
            [str(launcher or self.launcher), *arguments],
            input=stdin,
            capture_output=True,
            env=self.environment,
            cwd=self.root,
        )

    def test_portable_pair_uses_adjacent_app_and_preserves_call(self):
        app = self.app(self.pair / "WinMux.app", "portable", exit_code=19)
        gui = app / "Contents" / "MacOS" / "WinMux"
        original_gui = gui.read_bytes()
        arguments = ["agent", "--stdin", "", "a b", "$(touch unexpected)", "a'b"]
        result = self.invoke(*arguments, stdin=b"input\nwith\x00bytes\n")
        self.assertEqual(result.returncode, 19)
        self.assertEqual(
            result.stdout,
            b"portable\n" + b"".join(a.encode() + b"\0" for a in arguments)
            + b"\ninput\nwith\x00bytes\n",
        )
        self.assertEqual(result.stderr, b"")
        self.assertFalse((self.root / "unexpected").exists())
        self.assertEqual(gui.read_bytes(), original_gui)
        self.assertFalse(gui.samefile(app / "Contents" / "Helpers" / "winmux"))

    def test_missing_helper_never_falls_back_to_gui_case_variant(self):
        app = self.app(self.pair / "WinMux.app", "portable")
        (app / "Contents" / "Helpers" / "winmux").unlink()
        result = self.invoke("--version")
        self.assertEqual(result.returncode, 127)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"bundled CLI not found", result.stderr)
        self.assertNotIn(b"GUI must not run as CLI", result.stderr)

    def test_installed_config_follows_atomic_app_replacement(self):
        self.app(self.pair / "WinMux.app", "old archive")
        installed = self.app(self.root / "Applications" / "WinMux.app", "version one")
        self.config.write_text(f"{installed}\n")
        self.assertEqual(self.invoke().stdout, b"version one\n\n")
        installed.rename(installed.with_name("Previous.app"))
        self.app(installed, "version two")
        self.assertEqual(self.invoke().stdout, b"version two\n\n")

    def test_config_lookup_through_current_and_relative_launcher_symlinks(self):
        installed = self.app(self.root / "Apps ' $(literal)" / "WinMux.app", "installed")
        self.config.write_text(f"{installed}\n")
        current = self.root / "current"
        current.symlink_to(self.pair, target_is_directory=True)
        link = self.root / "winmux-link"
        link.symlink_to("current/bin/winmux")
        self.assertEqual(self.invoke(launcher=link).stdout, b"installed\n\n")

    def test_explicit_override_wins_over_config_and_portable_app(self):
        self.app(self.pair / "WinMux.app", "portable")
        configured = self.app(self.root / "configured.app", "configured")
        override = self.app(self.root / "override.app", "override")
        self.config.write_text(f"{configured}\n")
        self.environment["WINMUX_APP_PATH"] = str(override)
        self.assertEqual(self.invoke().stdout, b"override\n\n")

    def test_missing_explicit_app_does_not_fall_back(self):
        self.app(self.pair / "WinMux.app", "stale portable")
        self.environment["WINMUX_APP_PATH"] = str(self.root / "missing.app")
        result = self.invoke()
        self.assertEqual(result.returncode, 127)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"bundled CLI not found", result.stderr)

    def test_missing_configured_app_does_not_fall_back(self):
        self.app(self.pair / "WinMux.app", "stale portable")
        self.config.write_text(f"{self.root / 'missing.app'}\n")
        result = self.invoke()
        self.assertEqual(result.returncode, 127)
        self.assertEqual(result.stdout, b"")

    def test_invalid_app_paths_are_rejected(self):
        for value in ("", "relative/WinMux.app", "/Applications/WinMux.app\n/another.app"):
            with self.subTest(value=value):
                self.environment["WINMUX_APP_PATH"] = value
                result = self.invoke()
                self.assertEqual(result.returncode, 127)
                self.assertEqual(result.stdout, b"")

    def test_nonexecutable_embedded_cli_is_rejected(self):
        app = self.app(self.pair / "WinMux.app", "portable")
        (app / "Contents" / "Helpers" / "winmux").chmod(0o644)
        self.assertEqual(self.invoke().returncode, 127)


if __name__ == "__main__":
    unittest.main()
