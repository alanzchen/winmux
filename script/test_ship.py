"""Unattended local preview releases."""

import argparse
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("ship", Path(__file__).with_name("ship.py"))
ship = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ship)

COMMIT = "a" * 40


def feed(version):
    return (f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
            f'<sparkle:version>{version}</sparkle:version></item></channel></rss>').encode()


def write_assets(directory, version):
    directory.mkdir(parents=True, exist_ok=True)
    assets = []
    for name in [f"WinMux-{version}.zip", f"WinMux-{version}-macOS.zip", f"WinMux-{version}.dmg", "appcast.xml", "SHA256SUMS"]:
        path = directory / name
        path.write_bytes(name.encode())
        assets.append({"name": name, "state": "uploaded", "size": path.stat().st_size,
                       "digest": "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()})
    return assets


class FakeGitHub:
    """Answers the commands verify_release runs."""

    def __init__(self, record, tag_commit=COMMIT, offered="0.6.9"):
        self.record, self.tag_commit, self.offered = record, tag_commit, offered

    def __call__(self, *args):
        if args[:2] == ("gh", "api") and "/releases/tags/" in args[2]:
            if self.record is None:
                raise ValueError("gh: Not Found (HTTP 404)")
            return json.dumps(self.record)
        if args[:2] == ("gh", "api") and "/contents/" in args[2]:
            return json.dumps({"content": base64.b64encode(feed(self.offered)).decode()})
        if args[:2] == ("git", "ls-remote"):
            return f"{self.tag_commit}\trefs/tags/v0.6.9\n"
        raise AssertionError(f"unexpected command {args}")


def status_data(state="running", **values):
    data = {"run": "run-1", "state": state, "started": time.time() - 90, "ended": None, "phase": "build",
            "phases": [{"name": "preflight", "started": 0, "ended": 5}, {"name": "build", "started": 5, "ended": None}],
            "tag": "v0.6.9", "url": None, "checks": [], "error": [], "commit": COMMIT, "log": "/tmp/log.txt",
            "pid": None}
    data.update(values)
    return data


class SettingsTest(unittest.TestCase):
    def test_environment_wins_then_settings_file_then_defaults(self):
        settings = ship.resolve_settings({"DEVELOPMENT_TEAM": "ENV", "TOOLCHAINS": ""},
                                         {"TOOLCHAINS": "file.toolchain", "DEVELOPMENT_TEAM": "FILE"}, "/xcode/swiftc")
        self.assertEqual(settings["DEVELOPMENT_TEAM"], "ENV")
        self.assertEqual(settings["TOOLCHAINS"], "file.toolchain")
        self.assertEqual(settings["CODESIGN_IDENTITY"], "Developer ID Application")
        self.assertEqual(settings["SWIFT_EXEC_MANIFEST"], "/xcode/swiftc")

    def test_settings_file_is_key_value_lines(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ship.env"
            path.write_text('# comment\n\nTOOLCHAINS = "org.swift.x"\nWINMUX_SHIP_NOTIFY=say done\n')
            self.assertEqual(ship.read_settings_file(path), {"TOOLCHAINS": "org.swift.x", "WINMUX_SHIP_NOTIFY": "say done"})
            path.write_text("TOOLCHAINS\n")
            with self.assertRaisesRegex(ValueError, "expected KEY=VALUE"):
                ship.read_settings_file(path)
        self.assertEqual(ship.read_settings_file(Path("/nonexistent/ship.env")), {})

    def test_release_environment_drops_the_callers_make_variables(self):
        settings = ship.resolve_settings({}, {}, "/xcode/swiftc")
        env = ship.release_environment({"PATH": "/bin", "MAKEFLAGS": "-j", "MAKELEVEL": "1", "VERSION": "0.0.0-SNAPSHOT",
                                        "RELEASE_DERIVED_DATA_DIR": "/other/checkout/.local/release-cache"}, settings)
        self.assertEqual(env["PATH"], "/bin")
        for key in ("MAKEFLAGS", "MAKELEVEL", "VERSION", "RELEASE_DERIVED_DATA_DIR"):
            self.assertNotIn(key, env)
        self.assertEqual(env["RELEASE_BRANCH"], "main")
        self.assertEqual(env["PYTHONUNBUFFERED"], "1")
        self.assertEqual(env["SWIFT_EXEC_MANIFEST"], "/xcode/swiftc")


class SourceTest(unittest.TestCase):
    def test_only_the_tip_or_a_fast_forward_can_be_released(self):
        history = {("tip", "ahead"), ("old", "tip")}
        ancestor = lambda a, b: (a, b) in history
        self.assertEqual(ship.relation("tip", "tip", ancestor), "published")
        self.assertEqual(ship.relation("ahead", "tip", ancestor), "ahead")
        self.assertEqual(ship.relation("old", "tip", ancestor), "behind")
        self.assertEqual(ship.relation("other", "tip", ancestor), "diverged")


class WorktreeTest(unittest.TestCase):
    def git(self, *args, cwd):
        return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()

    def test_release_worktree_is_created_reused_and_never_wiped(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            (source / "Sources/Common").mkdir(parents=True)
            self.git("init", "--quiet", cwd=source)
            for name in [*ship.GENERATED, "README.md"]:
                (source / name).write_text("original\n")
            self.git("add", ".", cwd=source)
            self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-m", "one", cwd=source)
            first = self.git("rev-parse", "HEAD", cwd=source)
            (source / "README.md").write_text("second\n")
            self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-am", "two", cwd=source)
            second = self.git("rev-parse", "HEAD", cwd=source)
            common = self.git("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=source)
            release = Path(directory) / "release"

            ship.prepare_worktree(release, first, common, source)
            self.assertEqual(self.git("rev-parse", "HEAD", cwd=release), first)

            # A stopped release leaves its version stamps; they're restored, then the new commit checked out.
            (release / ship.GENERATED[1]).write_text("stamped\n")
            ship.prepare_worktree(release, second, common, source)
            self.assertEqual(self.git("rev-parse", "HEAD", cwd=release), second)
            self.assertEqual((release / ship.GENERATED[1]).read_text(), "original\n")

            (release / "README.md").write_text("someone's edit\n")
            with self.assertRaisesRegex(ValueError, "has changes"):
                ship.prepare_worktree(release, first, common, source)
            self.assertEqual((release / "README.md").read_text(), "someone's edit\n")

            other = Path(directory) / "other"
            other.mkdir()
            self.git("init", "--quiet", cwd=other)
            with self.assertRaisesRegex(ValueError, "isn't a worktree of this repository"):
                ship.prepare_worktree(other, first, common, source)


class LockTest(unittest.TestCase):
    def test_one_release_at_a_time_and_stale_locks_are_taken_over(self):
        with tempfile.TemporaryDirectory() as directory:
            lock = ship.ShipLock(Path(directory) / "ship.lock")
            lock.acquire("run-1")
            self.assertEqual(lock.owner(), {"pid": os.getpid(), "run": "run-1"})
            with self.assertRaisesRegex(ValueError, "run-1 is still running"):
                ship.ShipLock(lock.path).acquire("run-2", lambda owner: "running")
            # Its run already ended (the runner is just finishing up).
            ship.ShipLock(lock.path).acquire("run-2", lambda owner: "succeeded")
            self.assertEqual(lock.owner()["run"], "run-2")
            lock.hand_over(999_999_999, "run-2")
            with patch.object(ship, "pid_alive", return_value=False):
                ship.ShipLock(lock.path).acquire("run-3", lambda owner: "running")
            self.assertEqual(lock.owner()["run"], "run-3")

    def test_only_its_owner_releases_the_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            lock = ship.ShipLock(Path(directory) / "ship.lock")
            lock.acquire("run-1")
            lock.hand_over(4242, "run-1")
            lock.release(1111)
            self.assertTrue(lock.path.exists())
            lock.release(1111, 4242)
            self.assertFalse(lock.path.exists())
            lock.hand_over(4242, "run-1")  # A late handover after the run finished.
            self.assertFalse(lock.path.exists())


class TrackerTest(unittest.TestCase):
    def tracker(self, directory):
        return ship.PhaseTracker(ship.Status.create(directory, run="run-1", commit=COMMIT, log="log.txt", pid=None))

    def test_follows_markers_forward_and_ignores_script_test_output(self):
        with tempfile.TemporaryDirectory() as directory:
            tracker = self.tracker(directory)
            for line in ["::phase:: preflight", "::tag:: v0.6.9", "::phase:: tests",
                         # The release scripts' own unit tests print these.
                         "Prepared v0.6.303 from commit.", "Published preview https://example/v0.6.302 and advanced the feed.",
                         "Conducting pre-submission checks for WinMux-0.6.9.zip", "::phase:: build",
                         "Conducting pre-submission checks for WinMux-0.6.9.zip and initiating connection",
                         "::phase:: tests", "::phase:: publish",
                         "Local preview ready: https://github.com/alanzchen/winmux/releases/tag/v0.6.9"]:
                tracker.observe(line + "\n")
            data = tracker.status.data
            self.assertEqual([phase["name"] for phase in data["phases"]], ["preflight", "tests", "build", "notarize", "publish"])
            self.assertEqual(data["tag"], "v0.6.9")
            self.assertEqual(data["url"], "https://github.com/alanzchen/winmux/releases/tag/v0.6.9")
            self.assertTrue(all(phase["ended"] for phase in data["phases"][:-1]))

    def test_error_excerpt_keeps_failures_and_the_exit_reason(self):
        lines = ["[12/700] Compiling AppBundle TomlParseError.swift",
                 "Test Case '-[A.B testX]' started.", "Test Case '-[A.B testX]' passed (0.1 seconds).",
                 "/src/A.swift:3: error: -[A.B testY] : XCTAssertEqual failed",
                 "Test Case '-[A.B testY]' failed (0.2 seconds).",
                 "\t Executed 12 tests, with 0 failures (0 unexpected)",
                 "make: *** [prerelease-local] Error 1", "Command exited with 1"]
        excerpt = ship.error_excerpt(lines)
        self.assertIn("/src/A.swift:3: error: -[A.B testY] : XCTAssertEqual failed", excerpt)
        self.assertIn("Test Case '-[A.B testY]' failed (0.2 seconds).", excerpt)
        self.assertEqual(excerpt[-1], "Command exited with 1")
        self.assertFalse(any("Compiling" in line or "passed" in line or "0 failures" in line for line in excerpt))
        self.assertEqual(len(excerpt), len(set(excerpt)))


class VerifyTest(unittest.TestCase):
    def test_published_release_passes_every_check(self):
        with tempfile.TemporaryDirectory() as directory:
            assets = write_assets(Path(directory), "0.6.9")
            github = FakeGitHub({"draft": False, "prerelease": True, "assets": assets})
            checks = ship.verify_release("v0.6.9", COMMIT, directory, run=github)
            self.assertEqual({check["name"]: check["ok"] for check in checks},
                             {"release": True, "assets": True, "tag": True, "feed": True, "gatekeeper": False})

    def test_mismatches_are_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            assets = write_assets(Path(directory), "0.6.9")
            assets[0]["digest"] = "sha256:other"
            github = FakeGitHub({"draft": True, "prerelease": True, "assets": assets}, tag_commit="b" * 40, offered="0.6.8")
            checks = {check["name"]: check for check in ship.verify_release("v0.6.9", COMMIT, directory, run=github)}
            for name in ("release", "assets", "tag", "feed"):
                self.assertFalse(checks[name]["ok"], name)
            self.assertIn("offers 0.6.8, expected 0.6.9", checks["feed"]["detail"])

    def test_newer_feed_and_release_built_elsewhere_are_fine(self):
        assets = [{"name": name, "state": "uploaded"} for name in
                  ["WinMux-0.6.9.zip", "WinMux-0.6.9-macOS.zip", "WinMux-0.6.9.dmg", "appcast.xml", "SHA256SUMS"]]
        github = FakeGitHub({"draft": False, "prerelease": True, "assets": assets}, offered="0.6.10")
        checks = {check["name"]: check for check in ship.verify_release("v0.6.9", COMMIT, "/nonexistent", run=github)}
        self.assertTrue(checks["assets"]["ok"])
        self.assertIn("another checkout", checks["assets"]["detail"])
        self.assertTrue(checks["feed"]["ok"])
        self.assertNotIn("gatekeeper", checks)

    def test_missing_release_fails(self):
        checks = ship.verify_release("v0.6.9", COMMIT, "/nonexistent", run=FakeGitHub(None))
        self.assertEqual([(check["name"], check["ok"]) for check in checks], [("release", False)])


class SummaryTest(unittest.TestCase):
    def test_success_and_failure_fit_in_a_few_lines(self):
        data = status_data("succeeded", ended=None, url="https://example/v0.6.9", checks=[
            {"name": "release", "ok": True, "detail": "published prerelease"},
            {"name": "feed", "ok": True, "detail": "preview feed offers 0.6.9"}])
        data["started"], data["ended"] = 0, 392
        data["phases"][-1]["ended"] = 392
        summary = ship.summarize(data).splitlines()
        self.assertEqual(summary[0], "Published WinMux 0.6.9 preview: https://example/v0.6.9")
        self.assertEqual(summary[1], f"Commit {COMMIT[:8]}, 6m32s (preflight 5s, build 6m27s)")
        self.assertEqual(summary[2], "Checks passed: published prerelease; preview feed offers 0.6.9")
        self.assertEqual(summary[3], "Log: /tmp/log.txt")

        data.update(state="failed", error=["make: *** Error 1"], checks=[{"name": "feed", "ok": False, "detail": "offers 0.6.8"}])
        summary = ship.summarize(data).splitlines()
        self.assertEqual(summary[0], f"Release failed during build after 6m32s (commit {COMMIT[:8]}, v0.6.9).")
        self.assertEqual(summary[1:], ["  feed: offers 0.6.8", "  make: *** Error 1", "Log: /tmp/log.txt"])


class WaitTest(unittest.TestCase):
    def wait(self, run_dir, statuses=(), timeout=60, pid_alive=True):
        """Runs `wait`; each sleep advances to the next status."""
        pending = list(statuses)
        clock = [0.0]

        def sleep(_seconds):
            clock[0] += 5
            if pending:
                (run_dir / "status.json").write_text(json.dumps(pending.pop(0)))

        settings = {"WINMUX_RELEASE_WORKTREE": str(run_dir.parent.parent.parent)}
        args = argparse.Namespace(run=run_dir.name, timeout=timeout, interval=5, settings=settings)
        output = io.StringIO()
        with patch.object(ship, "pid_alive", return_value=pid_alive), contextlib.redirect_stdout(output):
            code = ship.wait(args, sleep=sleep, clock=lambda: clock[0])
        return code, output.getvalue()

    def run_dir(self, directory, data):
        run_dir = Path(directory) / ".local/ship/run-1"
        run_dir.mkdir(parents=True)
        (run_dir / "status.json").write_text(json.dumps(data))
        return run_dir

    def test_waits_quietly_then_prints_the_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            run_dir = self.run_dir(directory, status_data(pid=1234))
            (run_dir / "summary.txt").write_text("Published WinMux 0.6.9 preview: url\n")
            finished = status_data("succeeded", pid=1234)
            code, output = self.wait(run_dir, [status_data(pid=1234), finished])
            self.assertEqual(code, 0)
            self.assertEqual(output, "Waiting for release run-1 (build)...\nPublished WinMux 0.6.9 preview: url\n")

    def test_failure_exits_one(self):
        with tempfile.TemporaryDirectory() as directory:
            run_dir = self.run_dir(directory, status_data("failed", pid=1234, error=["boom"], ended=time.time()))
            code, output = self.wait(run_dir)
            self.assertEqual(code, 1)
            self.assertIn("Release failed during build", output)
            self.assertIn("boom", output)

    def test_runner_that_died_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "log.txt"
            log.write_text("building\nKilled: 9\nfatal: runner lost\n")
            run_dir = self.run_dir(directory, status_data(pid=1234, log=str(log)))
            code, output = self.wait(run_dir, pid_alive=False)
            self.assertEqual(code, 1)
            self.assertIn("stopped during build without finishing", output)
            self.assertIn("fatal: runner lost", output)

    def test_timeout_leaves_the_release_running(self):
        with tempfile.TemporaryDirectory() as directory:
            run_dir = self.run_dir(directory, status_data(pid=1234))
            code, output = self.wait(run_dir, timeout=0.1)
            self.assertEqual(code, 2)
            self.assertIn("Still running: build", output)


class RunnerTest(unittest.TestCase):
    def test_runner_follows_the_release_verifies_and_releases_the_lock(self):
        script = "\n".join([
            "print('::phase:: preflight')", "print('::tag:: v0.6.9')", "print('::phase:: tests')",
            "print('::phase:: build')", "print('Conducting pre-submission checks for WinMux-0.6.9.zip')",
            "print('::phase:: publish')", "print('Local preview ready: https://example/v0.6.9')"])
        with tempfile.TemporaryDirectory() as directory:
            code, data, summary, lock = self.run_release(directory, [sys.executable, "-c", script],
                                                         checks=[{"name": "feed", "ok": True, "detail": "feed ok"}])
            self.assertEqual(code, 0)
            self.assertEqual(data["state"], "succeeded")
            self.assertEqual([phase["name"] for phase in data["phases"]],
                             ["preflight", "tests", "build", "notarize", "publish", "verify"])
            self.assertTrue(summary.startswith("Published WinMux 0.6.9 preview: https://example/v0.6.9\n"))
            self.assertFalse(lock.path.exists())

    def test_failed_release_reports_its_phase_and_error(self):
        script = "import sys\nprint('::phase:: tests')\nprint('/src/A.swift:3: error: nope')\nsys.exit('Tests failed')"
        with tempfile.TemporaryDirectory() as directory:
            code, data, summary, lock = self.run_release(directory, [sys.executable, "-c", script])
            self.assertEqual(code, 1)
            self.assertEqual(data["phase"], "tests")
            self.assertIn("/src/A.swift:3: error: nope", data["error"])
            self.assertIn("Tests failed", data["error"])
            self.assertTrue(summary.startswith("Release failed during tests"))
            self.assertFalse(lock.path.exists())

    def run_release(self, directory, command, checks=()):
        run_dir = Path(directory) / "run-1"
        run_dir.mkdir()
        lock = ship.ShipLock(Path(directory) / "ship.lock")
        lock.acquire("run-1")
        starter = os.getpid()
        settings = ship.resolve_settings({}, {}, "")
        (run_dir / "request.json").write_text(json.dumps({
            "commit": COMMIT, "worktree": directory, "lock": str(lock.path), "starter": starter,
            "settings": settings, "command": command}))
        ship.Status.create(run_dir, run="run-1", commit=COMMIT, log=str(run_dir / "log.txt"), pid=None)
        with patch.object(ship, "verify_release", return_value=list(checks)), patch.object(ship, "notify"):
            code = ship.run_release(argparse.Namespace(run_dir=str(run_dir)))
        return code, json.loads((run_dir / "status.json").read_text()), (run_dir / "summary.txt").read_text(), lock


if __name__ == "__main__":
    unittest.main()
