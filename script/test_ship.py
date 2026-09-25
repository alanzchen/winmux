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
import signal
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
# Keeps the developer's git configuration (signing, hooks) out of the repositories tests create.
ISOLATED_GIT = {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "t",
                "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}


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

    def __init__(self, record, tag_commit=COMMIT, offered="0.6.9", feed_content=None, failures=0):
        self.record, self.tag_commit, self.offered = record, tag_commit, offered
        self.feed_content, self.failures, self.calls = feed_content, failures, 0

    def __call__(self, *args):
        self.calls += 1
        if self.failures:
            self.failures -= 1
            raise ValueError("gh: connection reset")
        if args[:2] == ("gh", "api") and "/releases/tags/" in args[2]:
            if self.record is None:
                raise ValueError("gh: Not Found (HTTP 404)")
            return json.dumps(self.record)
        if args[:2] == ("gh", "api") and "/contents/" in args[2]:
            return json.dumps({"content": self.feed_content or base64.b64encode(feed(self.offered)).decode()})
        if args[:2] == ("git", "ls-remote"):
            return f"{self.tag_commit}\trefs/tags/v0.6.9\n"
        raise AssertionError(f"unexpected command {args}")


def notarized(_dmg):
    return True, "DMG accepted as notarized Developer ID"


def status_data(state="running", **values):
    data = {"run": "run-1", "state": state, "started": time.time() - 90, "ended": None, "phase": "build",
            "phases": [{"name": "preflight", "started": 0, "ended": 5}, {"name": "build", "started": 5, "ended": None}],
            "tag": "v0.6.9", "url": None, "checks": [], "error": [], "commit": COMMIT, "log": "/tmp/log.txt",
            "pid": None, "child": None}
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

    def test_release_environment_carries_the_settings_and_drops_the_callers_variables(self):
        settings = ship.resolve_settings({}, {"DEVELOPMENT_TEAM": "TEAM"}, "")
        env = ship.release_environment({"PATH": "/bin", "MAKEFLAGS": "-j", "MAKELEVEL": "1", "VERSION": "0.0.0-SNAPSHOT",
                                        "RELEASE_DERIVED_DATA_DIR": "/other/checkout/.local/release-cache",
                                        "GITHUB_ACTIONS": "true", "GITHUB_REF": "refs/heads/x",
                                        "SWIFT_EXEC_MANIFEST": "/stale"}, settings)
        self.assertEqual(env["PATH"], "/bin")
        for key in ("MAKEFLAGS", "MAKELEVEL", "VERSION", "RELEASE_DERIVED_DATA_DIR", "GITHUB_ACTIONS", "GITHUB_REF",
                    "SWIFT_EXEC_MANIFEST"):
            self.assertNotIn(key, env)
        self.assertEqual(env["DEVELOPMENT_TEAM"], "TEAM")
        self.assertEqual(env["CODESIGN_IDENTITY"], "Developer ID Application")
        self.assertTrue(env["NOTARYTOOL_KEYCHAIN"].endswith("login.keychain-db"))
        self.assertEqual(env["RELEASE_BRANCH"], "main")
        self.assertEqual(env["PYTHONUNBUFFERED"], "1")


class SourceTest(unittest.TestCase):
    def test_only_the_tip_or_a_fast_forward_can_be_released(self):
        history = {("tip", "ahead"), ("old", "tip")}
        ancestor = lambda a, b: (a, b) in history
        self.assertEqual(ship.relation("tip", "tip", ancestor), "published")
        self.assertEqual(ship.relation("ahead", "tip", ancestor), "ahead")
        self.assertEqual(ship.relation("old", "tip", ancestor), "behind")
        self.assertEqual(ship.relation("other", "tip", ancestor), "diverged")


class WorktreeTest(unittest.TestCase):
    def setUp(self):
        environment = patch.dict(os.environ, ISOLATED_GIT)
        environment.start()
        self.addCleanup(environment.stop)

    def git(self, *args, cwd):
        return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()

    def repository(self, directory):
        source = Path(directory) / "source"
        (source / "Sources/Common").mkdir(parents=True)
        self.git("init", "--quiet", cwd=source)
        for name in [*ship.GENERATED, "README.md"]:
            (source / name).write_text("original\n")
        self.git("add", ".", cwd=source)
        self.git("commit", "--quiet", "-m", "one", cwd=source)
        first = self.git("rev-parse", "HEAD", cwd=source)
        (source / "README.md").write_text("second\n")
        self.git("commit", "--quiet", "-am", "two", cwd=source)
        second = self.git("rev-parse", "HEAD", cwd=source)
        common = self.git("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=source)
        return source, common, first, second

    def test_release_worktree_is_created_reused_and_never_wiped(self):
        with tempfile.TemporaryDirectory() as directory:
            source, common, first, second = self.repository(directory)
            release = Path(directory) / "release"

            ship.prepare_worktree(release, first, common, source)
            self.assertEqual(self.git("rev-parse", "HEAD", cwd=release), first)

            # A stopped release leaves version stamps (even staged ones) and its lock; both are cleared.
            (release / ship.GENERATED[0]).write_text("stamped\n")
            (release / ship.GENERATED[1]).write_text("stamped\n")
            self.git("add", ship.GENERATED[1], cwd=release)
            (release / ".local/prerelease.lock").mkdir(parents=True)
            with contextlib.redirect_stdout(io.StringIO()):
                ship.prepare_worktree(release, second, common, source)
            self.assertEqual(self.git("rev-parse", "HEAD", cwd=release), second)
            self.assertEqual(self.git("status", "--porcelain", cwd=release), "")
            self.assertFalse((release / ".local/prerelease.lock").exists())

            (release / "README.md").write_text("someone's edit\n")
            with self.assertRaisesRegex(ValueError, "has changes"):
                ship.prepare_worktree(release, first, common, source)
            self.assertEqual((release / "README.md").read_text(), "someone's edit\n")

            other = Path(directory) / "other"
            other.mkdir()
            self.git("init", "--quiet", cwd=other)
            with self.assertRaisesRegex(ValueError, "isn't a worktree of this repository"):
                ship.prepare_worktree(other, first, common, source)

    def test_deleted_but_still_registered_worktree_is_recreated(self):
        with tempfile.TemporaryDirectory() as directory:
            source, common, first, second = self.repository(directory)
            release = Path(directory) / "release"
            ship.prepare_worktree(release, first, common, source)
            subprocess.run(["rm", "-rf", str(release)], check=True)

            ship.prepare_worktree(release, second, common, source)

            self.assertEqual(self.git("rev-parse", "HEAD", cwd=release), second)


class LockTest(unittest.TestCase):
    def test_one_release_at_a_time_and_finished_runs_are_taken_over(self):
        with tempfile.TemporaryDirectory() as directory:
            lock = ship.ShipLock(Path(directory) / "ship.lock")
            lock.acquire("run-1")
            self.assertEqual(lock.owner(), {"pid": os.getpid(), "run": "run-1"})
            with self.assertRaisesRegex(ValueError, "run-1 is still running"):
                ship.ShipLock(lock.path).acquire("run-2", lambda owner: True)
            ship.ShipLock(lock.path).acquire("run-2", lambda owner: False)
            self.assertEqual(lock.owner()["run"], "run-2")

    def test_handover_and_release_only_touch_their_own_run(self):
        with tempfile.TemporaryDirectory() as directory:
            lock = ship.ShipLock(Path(directory) / "ship.lock")
            lock.acquire("run-2")
            # A late handover from an earlier run can't take over this one.
            lock.hand_over(4242, "run-1")
            lock.release("run-1")
            self.assertEqual(lock.owner(), {"pid": os.getpid(), "run": "run-2"})
            lock.hand_over(4242, "run-2")
            self.assertEqual(lock.owner(), {"pid": 4242, "run": "run-2"})
            lock.release("run-2")
            self.assertFalse(lock.path.exists())
            lock.hand_over(4242, "run-2")
            self.assertFalse(lock.path.exists())

    def test_unreadable_owner_is_left_to_the_age_check(self):
        with tempfile.TemporaryDirectory() as directory:
            lock = ship.ShipLock(Path(directory) / "ship.lock")
            lock.path.mkdir()
            lock.release("run-1")
            self.assertTrue(lock.path.exists())
            with self.assertRaisesRegex(ValueError, "starting"):
                lock.acquire("run-2")
            old = time.time() - 60
            os.utime(lock.path, (old, old))
            lock.acquire("run-2")
            self.assertEqual(lock.owner()["run"], "run-2")

    def test_a_run_is_active_while_any_of_its_processes_lives(self):
        with tempfile.TemporaryDirectory() as directory:
            runs = Path(directory)
            (runs / "run-1").mkdir()
            owner = {"pid": 11, "run": "run-1"}

            def active(state, alive=(), groups=()):
                (runs / "run-1/status.json").write_text(json.dumps({"state": state, "pid": 22, "child": 33}))
                with patch.object(ship, "pid_alive", side_effect=lambda pid: pid in alive), \
                        patch.object(ship, "group_alive", side_effect=lambda pgid: pgid in groups):
                    return ship.run_is_active(owner, runs)

            self.assertFalse(active("running"))
            # The starter died before handing over, but its runner lives.
            self.assertTrue(active("running", alive={22}))
            self.assertTrue(active("running", alive={11}))
            # A killed runner's build outlives it.
            self.assertTrue(active("failed", groups={33}))
            self.assertFalse(active("succeeded", alive={11, 22}))
            with patch.object(ship, "pid_alive", return_value=True):
                self.assertTrue(ship.run_is_active({"pid": 11, "run": "missing"}, runs))


class TrackerTest(unittest.TestCase):
    def tracker(self, directory):
        return ship.PhaseTracker(ship.Status.create(directory, run="run-1", commit=COMMIT, log="log.txt"))

    def test_follows_markers_forward_and_ignores_script_test_output(self):
        with tempfile.TemporaryDirectory() as directory:
            tracker = self.tracker(directory)
            for line in ["::phase:: preflight", "::tag:: v0.6.9", "::phase:: tests",
                         # The release scripts' own unit tests print these.
                         "Prepared v0.6.303 from commit.", "Published preview https://example/v0.6.302 and advanced the feed.",
                         "::tag:: v0.6.302", "Local preview ready: https://example/v0.6.302",
                         "Conducting pre-submission checks for WinMux-0.6.9.zip", "::phase:: build",
                         "Conducting pre-submission checks for WinMux-0.6.9.zip and initiating connection",
                         "::phase:: tests", "::phase:: publish"]:
                tracker.observe(line + "\n")
            data = tracker.status.data
            self.assertEqual([phase["name"] for phase in data["phases"]], ["preflight", "tests", "build", "notarize", "publish"])
            self.assertEqual(data["tag"], "v0.6.9")
            self.assertEqual(data["url"], "https://example/v0.6.302")
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
        # Only room for the tail: the last three meaningful lines.
        self.assertEqual(ship.error_excerpt(lines, limit=3),
                         ["Test Case '-[A.B testY]' failed (0.2 seconds).", "make: *** [prerelease-local] Error 1",
                          "Command exited with 1"])


class VerifyTest(unittest.TestCase):
    def test_published_release_passes_every_check(self):
        with tempfile.TemporaryDirectory() as directory:
            assets = write_assets(Path(directory), "0.6.9")
            github = FakeGitHub({"draft": False, "prerelease": True, "assets": assets})
            checks = ship.verify_release("v0.6.9", COMMIT, directory, run=github, assess=notarized)
            self.assertEqual({check["name"]: check["ok"] for check in checks},
                             {"release": True, "assets": True, "tag": True, "feed": True, "gatekeeper": True})

    def test_mismatches_are_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            assets = write_assets(Path(directory), "0.6.9")
            assets[0]["digest"] = "sha256:other"
            github = FakeGitHub({"draft": True, "prerelease": True, "assets": assets}, tag_commit="b" * 40, offered="0.6.8")
            checks = {check["name"]: check for check in
                      ship.verify_release("v0.6.9", COMMIT, directory, run=github, assess=lambda dmg: (False, "rejected"))}
            for name in ("release", "assets", "tag", "feed", "gatekeeper"):
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

    def test_missing_release_fails_without_asset_check(self):
        checks = ship.verify_release("v0.6.9", COMMIT, "/nonexistent", run=FakeGitHub(None))
        self.assertEqual([(check["name"], check["ok"]) for check in checks],
                         [("release", False), ("tag", True), ("feed", True)])

    def test_transient_errors_are_retried_and_broken_checks_never_raise(self):
        assets = [{"name": name, "state": "uploaded"} for name in
                  ["WinMux-0.6.9.zip", "WinMux-0.6.9-macOS.zip", "WinMux-0.6.9.dmg", "appcast.xml", "SHA256SUMS"]]
        pauses = []
        github = FakeGitHub({"draft": False, "prerelease": True, "assets": assets}, failures=2,
                            feed_content=base64.b64encode(b"<rss><channel>").decode())
        checks = {check["name"]: check for check in
                  ship.verify_release("v0.6.9", COMMIT, "/nonexistent", run=github, sleep=pauses.append)}
        self.assertEqual(pauses, [2, 4])
        self.assertTrue(checks["release"]["ok"])
        self.assertFalse(checks["feed"]["ok"])
        self.assertIn("couldn't check", checks["feed"]["detail"])

        unreachable = FakeGitHub(None, failures=99)
        checks = ship.verify_release("v0.6.9", COMMIT, "/nonexistent", run=unreachable, sleep=lambda _: None)
        self.assertIn("couldn't check: gh: connection reset", checks[0]["detail"])


class SummaryTest(unittest.TestCase):
    def test_each_outcome_fits_in_a_few_lines(self):
        data = status_data("succeeded", url="https://example/v0.6.9", checks=[
            {"name": "release", "ok": True, "detail": "published prerelease"},
            {"name": "feed", "ok": True, "detail": "preview feed offers 0.6.9"}])
        data["started"], data["ended"] = 0, 392
        data["phases"][-1]["ended"] = 392
        summary = ship.summarize(data).splitlines()
        self.assertEqual(summary, [
            "Published WinMux 0.6.9 preview: https://example/v0.6.9",
            f"Commit {COMMIT[:8]}, 6m32s (preflight 5s, build 6m27s)",
            "Checks passed: published prerelease; preview feed offers 0.6.9",
            "Log: /tmp/log.txt"])

        data.update(state="unverified", checks=[{"name": "feed", "ok": False, "detail": "couldn't check: offline"}])
        summary = ship.summarize(data).splitlines()
        self.assertEqual(summary[0], "Published WinMux 0.6.9 preview, but a post-publication check failed: https://example/v0.6.9")
        self.assertEqual(summary[2:], ["  feed: couldn't check: offline", "Log: /tmp/log.txt"])

        data.update(state="failed", error=["make: *** Error 1"], checks=[])
        summary = ship.summarize(data).splitlines()
        self.assertEqual(summary, [f"Release failed during build after 6m32s (commit {COMMIT[:8]}, v0.6.9).",
                                   "  make: *** Error 1", "Log: /tmp/log.txt"])


class WaitTest(unittest.TestCase):
    def wait(self, run_dir, statuses=(), timeout=60, alive=True):
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
        with patch.object(ship, "pid_alive", return_value=alive), patch.object(ship, "group_alive", return_value=False), \
                contextlib.redirect_stdout(output):
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
            code, output = self.wait(run_dir, [status_data(pid=1234), status_data("succeeded", pid=1234)])
            self.assertEqual(code, 0)
            self.assertEqual(output, "Waiting for release run-1 (build)...\nPublished WinMux 0.6.9 preview: url\n")

    def test_exit_codes_tell_failed_from_published_with_a_failed_check(self):
        for state, expected in (("failed", 1), ("unverified", 3)):
            with tempfile.TemporaryDirectory() as directory:
                run_dir = self.run_dir(directory, status_data(state, pid=1234, url="url", error=["boom"], ended=time.time()))
                code, output = self.wait(run_dir)
                self.assertEqual(code, expected)
                self.assertIn("boom", output)

    def test_runner_that_died_is_reported_and_recorded(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "log.txt"
            log.write_text("building\nKilled: 9\n")
            run_dir = self.run_dir(directory, status_data(pid=1234, log=str(log)))
            (run_dir / "runner.log").write_text("Traceback (most recent call last):\nKeyError: 'schema'\n")
            code, output = self.wait(run_dir, alive=False)
            self.assertEqual(code, 1)
            self.assertIn("The release runner stopped without finishing.", output)
            self.assertIn("KeyError: 'schema'", output)
            self.assertEqual(json.loads((run_dir / "status.json").read_text())["state"], "failed")
            self.assertTrue((run_dir / "summary.txt").exists())

    def test_runner_that_never_started_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            run_dir = self.run_dir(directory, status_data("starting", pid=None, started=time.time() - 120))
            code, output = self.wait(run_dir)
            self.assertEqual(code, 1)
            self.assertIn("stopped without finishing", output)

    def test_timeout_leaves_the_release_running(self):
        with tempfile.TemporaryDirectory() as directory:
            run_dir = self.run_dir(directory, status_data(pid=1234))
            code, output = self.wait(run_dir, timeout=0.1)
            self.assertEqual(code, 2)
            self.assertIn("Still running: build", output)


class RunnerTest(unittest.TestCase):
    PUBLISHED = "\n".join([
        "print('::phase:: preflight')", "print('::tag:: v0.6.9')", "print('::phase:: tests')",
        "print('::phase:: build')", "print('Conducting pre-submission checks for WinMux-0.6.9.zip')",
        "print('::phase:: publish')", "print('Local preview ready: https://example/v0.6.9')"])

    def test_runner_follows_the_release_verifies_and_releases_the_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            before = signal.getsignal(signal.SIGTERM)
            code, data, summary, lock = self.run_release(directory, [sys.executable, "-c", self.PUBLISHED],
                                                         checks=[{"name": "feed", "ok": True, "detail": "feed ok"}])
            self.assertEqual(code, 0)
            self.assertEqual(data["state"], "succeeded")
            self.assertEqual([phase["name"] for phase in data["phases"]],
                             ["preflight", "tests", "build", "notarize", "publish", "verify"])
            self.assertTrue(summary.startswith("Published WinMux 0.6.9 preview: https://example/v0.6.9\n"))
            self.assertFalse(lock.path.exists())
            self.assertIs(signal.getsignal(signal.SIGTERM), before)

    def test_published_release_with_a_failed_check_is_unverified(self):
        with tempfile.TemporaryDirectory() as directory:
            code, data, summary, _ = self.run_release(directory, [sys.executable, "-c", self.PUBLISHED],
                                                      checks=[{"name": "feed", "ok": False, "detail": "offline"}])
            self.assertEqual((code, data["state"]), (3, "unverified"))
            self.assertIn("https://example/v0.6.9", summary.splitlines()[0])

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

    def test_request_from_another_version_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            code, data, _, lock = self.run_release(directory, [sys.executable, "-c", "print('never')"], schema=99)
            self.assertEqual(code, 1)
            self.assertIn("incompatible ship.py", data["error"][0])
            self.assertFalse(lock.path.exists())

    def test_stopping_the_release_stops_its_whole_process_group(self):
        script = "import subprocess, time\nsubprocess.Popen(['sleep', '60'])\nprint('ready', flush=True)\ntime.sleep(60)"
        process = subprocess.Popen([sys.executable, "-c", script], stdout=subprocess.PIPE, text=True, start_new_session=True)
        self.assertEqual(process.stdout.readline().strip(), "ready")
        ship.stop_process_group(process, grace=5)
        process.stdout.close()
        self.assertIsNotNone(process.returncode)
        deadline = time.time() + 5
        while ship.group_alive(process.pid) and time.time() < deadline:
            time.sleep(0.05)
        self.assertFalse(ship.group_alive(process.pid))

    def run_release(self, directory, command, checks=(), schema=None):
        run_dir = Path(directory) / "run-1"
        run_dir.mkdir()
        lock = ship.ShipLock(Path(directory) / "ship.lock")
        lock.acquire("run-1")
        (run_dir / "request.json").write_text(json.dumps({
            "schema": schema or ship.SCHEMA, "commit": COMMIT, "worktree": directory, "lock": str(lock.path),
            "settings": ship.resolve_settings({}, {}, ""), "command": command}))
        ship.Status.create(run_dir, run="run-1", commit=COMMIT, log=str(run_dir / "log.txt"))
        with patch.object(ship, "verify_release", return_value=list(checks)), patch.object(ship, "notify"):
            code = ship.run_release(argparse.Namespace(run_dir=str(run_dir)))
        return code, json.loads((run_dir / "status.json").read_text()), (run_dir / "summary.txt").read_text(), lock


class HousekeepingTest(unittest.TestCase):
    def test_old_finished_runs_are_pruned(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for index in range(5):
                (root / f"run-{index}").mkdir()
                state = "running" if index == 0 else "succeeded"
                (root / f"run-{index}/status.json").write_text(json.dumps({"state": state}))
            (root / "latest").write_text("run-4\n")
            ship.prune_runs(root, keep=2)
            self.assertEqual(sorted(path.name for path in root.iterdir()), ["latest", "run-0", "run-3", "run-4"])

    def test_notify_hook_gets_the_summary_and_no_release_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "hook.txt"
            data = status_data("succeeded", url="https://example/v0.6.9")
            hook = f"{{ cat; env | sort; }} > {output}"
            real_run, banners = subprocess.run, []

            def run(args, **kwargs):
                # No real banner from a test; the hook itself runs.
                if args[0] == "osascript":
                    banners.append(args[-2:])
                    return subprocess.CompletedProcess(args, 0)
                return real_run(args, **kwargs)

            with patch.object(ship.subprocess, "run", side_effect=run):
                ship.notify(data, "Published WinMux 0.6.9 preview\n", {"WINMUX_SHIP_NOTIFY": hook},
                            environ={"PATH": os.environ["PATH"], "HOME": "/home", "SPARKLE_PRIVATE_KEY": "secret"})
            self.assertEqual(banners, [["WinMux preview published", "0.6.9 is live"]])
            text = output.read_text()
            self.assertIn("Published WinMux 0.6.9 preview", text)
            self.assertIn("SHIP_URL=https://example/v0.6.9", text)
            self.assertIn("SHIP_OK=1", text)
            self.assertNotIn("secret", text)


if __name__ == "__main__":
    unittest.main()
