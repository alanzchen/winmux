#!/usr/bin/env python3
"""Publish a local preview unattended, then report it in a few lines.

    ship.py start [--commit REV] [--dry-run]
                                    check, push to main, and start the release in the background;
                                    --dry-run stops after the checks and preflight
    ship.py wait [RUN] [--timeout MINUTES]
                                    block until the release ends, print its summary, and exit 0
                                    when it was published, 1 when it failed, 2 on timeout
    ship.py status [RUN]            print one line about the latest (or given) run

Releases build in a dedicated worktree (default ~/Developer/winmux-worktrees/release), so they
never touch a checkout someone is working in, and keep their build caches between releases.
Each run keeps status.json, summary.txt, and log.txt in that worktree's .local/ship/<run>/.
Nothing depends on a particular coding agent: any caller can start a release, wait for it,
and read those files.
"""

import argparse
from collections import deque
import base64
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import xml.etree.ElementTree as ET


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


preview = load_module("ci_prerelease", "ci-prerelease.py")
BRANCH = "main"
PHASES = ("preflight", "tests", "build", "notarize", "publish", "verify")
TERMINAL = ("succeeded", "failed")
GENERATED = ("Sources/Common/gitHashGenerated.swift", "Sources/Common/versionGenerated.swift")
SETTINGS_FILE = Path.home() / "Library/Application Support/WinMux/ship.env"
DEFAULTS = {
    "CODESIGN_IDENTITY": "Developer ID Application",
    "DEVELOPMENT_TEAM": "N9YEGD9WDP",
    "NOTARYTOOL_KEYCHAIN": str(Path.home() / "Library/Keychains/login.keychain-db"),
    "TOOLCHAINS": "org.swift.624202602241a",
    "SWIFT_EXEC_MANIFEST": "",
    "WINMUX_RELEASE_WORKTREE": str(Path.home() / "Developer/winmux-worktrees/release"),
    # Optional shell command run when a release ends, with the summary on stdin.
    "WINMUX_SHIP_NOTIFY": "",
}
# Set by `make`; the release worktree's own make must choose them itself.
INHERITED_MAKE_VARIABLES = (
    "MAKEFLAGS", "MAKELEVEL", "MFLAGS", "MAKEOVERRIDES", "VERSION", "RELEASE_DIR", "RELEASE_TAG",
    "CLI_STAGE_PATH", "PUBLISH", "NOTARIZE", "GENERATE_APPCAST", "UPDATE_FEED_URL", "RELEASE_NOTES",
    "RELEASE_DERIVED_DATA_DIR",
)


def command(*args, cwd=None, env=None, check=True, strip=True):
    result = subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True)
    if check and result.returncode:
        output = (result.stderr or result.stdout).strip()
        raise ValueError(f"{' '.join(args)} failed: {output}")
    return result.stdout.strip() if strip else result.stdout


def git(*args, cwd=None, check=True, strip=True):
    return command("git", *args, cwd=cwd, check=check, strip=strip)


def is_ancestor(ancestor, descendant, cwd):
    return subprocess.run(["git", "merge-base", "--is-ancestor", ancestor, descendant], cwd=cwd).returncode == 0


def pid_alive(pid):
    if not pid:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def read_settings_file(path):
    values = {}
    if not path.exists():
        return values
    for number, line in enumerate(path.read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator:
            raise ValueError(f"{path}:{number}: expected KEY=VALUE")
        values[key.strip()] = value.strip().strip('"')
    return values


def resolve_settings(environ, file_values, xcode_swiftc):
    """The environment wins, then the settings file, then the documented defaults."""
    settings = {}
    for key, default in DEFAULTS.items():
        settings[key] = environ.get(key) or file_values.get(key) or default
    settings["SWIFT_EXEC_MANIFEST"] = settings["SWIFT_EXEC_MANIFEST"] or xcode_swiftc
    return settings


def load_settings():
    developer = command("xcode-select", "-p", check=False)
    swiftc = Path(developer) / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    return resolve_settings(os.environ, read_settings_file(SETTINGS_FILE), str(swiftc) if swiftc.exists() else "")


def release_environment(environ, settings):
    env = {key: value for key, value in environ.items() if key not in INHERITED_MAKE_VARIABLES}
    env.update(
        TOOLCHAINS=settings["TOOLCHAINS"],
        SWIFT_EXEC_MANIFEST=settings["SWIFT_EXEC_MANIFEST"],
        RELEASE_BRANCH=BRANCH,
        PYTHONUNBUFFERED="1",
    )
    return env


def relation(commit, tip, ancestor):
    if commit == tip:
        return "published"
    if ancestor(tip, commit):
        return "ahead"
    if ancestor(commit, tip):
        return "behind"
    return "diverged"


class ShipLock:
    """One release at a time across every worktree of the repository."""

    def __init__(self, path):
        self.path = Path(path)
        self.owner_path = self.path / "owner.json"

    def owner(self):
        try:
            return json.loads(self.owner_path.read_text())
        except (OSError, ValueError):
            return None

    def acquire(self, run_id, run_status=lambda owner: None):
        for _ in range(2):
            try:
                self.path.mkdir(parents=False)
            except FileExistsError:
                owner = self.owner()
                if owner is None and time.time() - self.path.stat().st_mtime < 30:
                    raise ValueError("Another release is starting; try again in a moment.")
                if owner and pid_alive(owner.get("pid")) and run_status(owner) not in TERMINAL:
                    raise ValueError(f"Release {owner.get('run')} is still running; wait for it with `make ship-wait`.")
                # Its process is gone: a stopped or crashed run.
                shutil.rmtree(self.path, ignore_errors=True)
                continue
            self.hand_over(os.getpid(), run_id)
            return
        raise ValueError(f"Couldn't take the release lock at {self.path}.")

    def hand_over(self, pid, run_id):
        try:
            self.owner_path.write_text(json.dumps({"pid": pid, "run": run_id}))
        except FileNotFoundError:
            pass  # The run already finished and released the lock.

    def release(self, *pids):
        owner = self.owner()
        if owner is None or owner.get("pid") in pids:
            shutil.rmtree(self.path, ignore_errors=True)


class Status:
    def __init__(self, run_dir):
        self.path = Path(run_dir) / "status.json"
        self.data = json.loads(self.path.read_text())

    @staticmethod
    def create(run_dir, **values):
        now = time.time()
        data = {"state": "starting", "started": now, "ended": None, "phase": "preflight",
                "phases": [{"name": "preflight", "started": now, "ended": None}],
                "tag": None, "url": None, "checks": [], "error": [], **values}
        path = Path(run_dir) / "status.json"
        path.write_text(json.dumps(data, indent=2))
        return Status(run_dir)

    def save(self):
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.data, indent=2))
        temporary.replace(self.path)

    def update(self, **values):
        self.data.update(values)
        self.save()

    def enter(self, name, now=None):
        now = now or time.time()
        phases = self.data["phases"]
        if phases and phases[-1]["ended"] is None:
            phases[-1]["ended"] = now
        phases.append({"name": name, "started": now, "ended": None})
        self.data["phase"] = name
        self.save()

    def finish(self, state, error=(), checks=None, now=None):
        now = now or time.time()
        if self.data["phases"] and self.data["phases"][-1]["ended"] is None:
            self.data["phases"][-1]["ended"] = now
        self.data.update(state=state, ended=now, error=list(error))
        if checks is not None:
            self.data["checks"] = checks
        self.save()


class PhaseTracker:
    """Follows the release log: phase markers from local-prerelease.py, the notarization
    handoff from build-release.sh, the tag, and the published URL."""

    NOTARIZATION = "Conducting pre-submission checks for "

    def __init__(self, status):
        self.status = status
        self.recent = deque(maxlen=400)

    @property
    def phase(self):
        return self.status.data["phase"]

    def enter(self, name):
        if name in PHASES and PHASES.index(name) > PHASES.index(self.phase):
            self.status.enter(name)

    def observe(self, line):
        line = line.rstrip("\n")
        self.recent.append(line)
        if line.startswith("::phase:: "):
            self.enter(line.split(None, 1)[1].strip())
        elif line.startswith("::tag:: "):
            self.status.update(tag=line.split(None, 1)[1].strip())
        elif line.startswith("Local preview ready: "):
            self.status.update(url=line.split(": ", 1)[1].strip())
        elif self.NOTARIZATION in line and self.phase == "build":
            self.enter("notarize")


ERROR_LINE = re.compile(r"error:|\bError\b|ERROR|failed|FAILED|[Rr]efusing|Traceback|fatal:|exited with")
NOISE_LINE = re.compile(r"^\[\d+/\d+\]|^Test Case .* (started\.|passed \()|with 0 failures")


def error_excerpt(lines, limit=12):
    """The lines that explain a failure: errors, then the last few lines (the exit reason)."""
    lines = [line for line in lines if line.strip() and not NOISE_LINE.search(line)]
    tail = lines[-3:]
    errors = [line for line in lines if ERROR_LINE.search(line) and line not in tail]
    picked = errors[-(limit - 3):] + tail
    seen = set()
    return [line[:300] for line in picked if not (line in seen or seen.add(line))]


def gh_json(path, run=command):
    try:
        return json.loads(run("gh", "api", path))
    except ValueError:
        return None


def verify_release(tag, commit, directory, run=command):
    """Read the published release back from GitHub. Returns a list of checks."""
    repo = preview.REPOSITORY
    version = tag[1:]
    checks = []

    def check(name, ok, detail):
        checks.append({"name": name, "ok": bool(ok), "detail": detail})

    record = gh_json(f"repos/{repo}/releases/tags/{tag}", run)
    if not record:
        check("release", False, f"GitHub has no release {tag}")
        return checks
    published = not record["draft"] and record["prerelease"]
    check("release", published, "published prerelease" if published
          else f"draft={record['draft']} prerelease={record['prerelease']}")

    uploaded = sorted(asset["name"] for asset in record["assets"] if asset["state"] == "uploaded")
    if Path(directory).is_dir():
        try:
            paths = preview.release.release_assets(tag, directory)
            preview.release.verify_uploaded_assets(paths, record["assets"])
            check("assets", True, f"{len(paths)} assets match the local build")
        except ValueError as error:
            check("assets", False, f"{error} (uploaded: {', '.join(uploaded) or 'none'})")
    else:
        # Published earlier from another checkout; same names as ci-release.release_assets.
        expected = sorted([f"WinMux-{version}.zip", f"WinMux-{version}-macOS.zip", f"WinMux-{version}.dmg",
                           "appcast.xml", "SHA256SUMS"])
        check("assets", uploaded == expected, f"{len(uploaded)} assets uploaded (built in another checkout)"
              if uploaded == expected else f"uploaded: {', '.join(uploaded) or 'none'}")

    refs = run("git", "ls-remote", f"https://github.com/{repo}.git", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}")
    tagged = dict(line.split()[::-1] for line in refs.splitlines() if line.strip())
    tag_commit = tagged.get(f"refs/tags/{tag}^{{}}", tagged.get(f"refs/tags/{tag}"))
    check("tag", tag_commit == commit, f"{tag} is {(tag_commit or 'missing')[:8]}, expected {commit[:8]}")

    feed = gh_json(f"repos/{repo}/contents/{preview.FEED_PATH}?ref={preview.FEED_BRANCH}", run)
    offered = None
    if feed:
        items = ET.fromstring(base64.b64decode(feed["content"])).findall("./channel/item")
        offered = items[0].findtext(preview.appcast.SPARKLE + "version") if items else None
    if offered == version:
        check("feed", True, f"preview feed offers {version}")
    elif offered and preview.release.version_tuple(f"v{offered}") > preview.release.version_tuple(tag):
        check("feed", True, f"preview feed already offers newer {offered}")
    else:
        check("feed", False, f"preview feed offers {offered or 'nothing'}, expected {version}")

    dmg = Path(directory) / f"WinMux-{version}.dmg"
    if dmg.is_file():
        result = subprocess.run(["spctl", "-a", "-vv", "-t", "install", str(dmg)], text=True, capture_output=True)
        output = result.stdout + result.stderr
        ok = result.returncode == 0 and "source=Notarized Developer ID" in output
        check("gatekeeper", ok, "DMG accepted as notarized Developer ID" if ok else output.strip()[-200:])
    return checks


def duration(seconds):
    seconds = int(round(seconds))
    return f"{seconds // 60}m{seconds % 60:02d}s" if seconds >= 60 else f"{seconds}s"


def summarize(data):
    total = duration((data["ended"] or time.time()) - data["started"])
    phases = ", ".join(f"{phase['name']} {duration(phase['ended'] - phase['started'])}"
                       for phase in data["phases"] if phase["ended"])
    commit = data["commit"][:8]
    lines = []
    if data["state"] == "succeeded":
        lines.append(f"Published WinMux {data['tag'][1:]} preview: {data['url']}")
        lines.append(f"Commit {commit}, {total} ({phases})")
        lines.append("Checks passed: " + "; ".join(check["detail"] for check in data["checks"]))
    else:
        lines.append(f"Release failed during {data['phase']} after {total} (commit {commit}"
                     + (f", {data['tag']}" if data["tag"] else "") + ").")
        lines += [f"  {check['name']}: {check['detail']}" for check in data["checks"] if not check["ok"]]
        lines += [f"  {line}" for line in data["error"]]
    lines.append(f"Log: {data['log']}")
    return "\n".join(lines) + "\n"


def notify(data, summary, settings):
    ok = data["state"] == "succeeded"
    title = "WinMux preview published" if ok else "WinMux release failed"
    message = f"{data['tag'][1:]} is live" if ok else f"Failed during {data['phase']}"
    subprocess.run(["osascript", "-e", "on run argv", "-e",
                    "display notification (item 2 of argv) with title (item 1 of argv)", "-e", "end run",
                    title, message], capture_output=True, timeout=10)
    hook = settings.get("WINMUX_SHIP_NOTIFY")
    if hook:
        env = dict(os.environ, SHIP_STATE=data["state"], SHIP_TAG=data["tag"] or "", SHIP_URL=data["url"] or "",
                   SHIP_LOG=data["log"])
        subprocess.run(hook, shell=True, input=summary, text=True, env=env, capture_output=True, timeout=60)


def runs_root(settings):
    return Path(settings["WINMUX_RELEASE_WORKTREE"]).expanduser() / ".local/ship"


def find_run(settings, run_id=None):
    root = runs_root(settings)
    if run_id is None:
        latest = root / "latest"
        if not latest.exists():
            raise ValueError(f"No releases have been started from {root.parent.parent}.")
        run_id = latest.read_text().strip()
    run_dir = root / run_id
    if not (run_dir / "status.json").exists():
        raise ValueError(f"No release run {run_id} in {root}.")
    return run_dir


def prepare_worktree(path, commit, common_dir, source):
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        git("worktree", "add", "--detach", "--quiet", str(path), commit, cwd=source)
        return
    other = Path(git("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=path))
    if other.resolve() != Path(common_dir).resolve():
        raise ValueError(f"{path} isn't a worktree of this repository; set WINMUX_RELEASE_WORKTREE.")
    # Unstripped: the status columns start with a space.
    changed = [line[3:] for line in git("status", "--porcelain", cwd=path, strip=False).splitlines() if line]
    leftovers = sorted(set(changed) - set(GENERATED))
    if leftovers:
        raise ValueError(f"The release worktree {path} has changes; inspect them before releasing:\n  "
                         + "\n  ".join(leftovers))
    if changed:
        # Version stamps left by a stopped release.
        git("checkout", "--quiet", "--", *changed, cwd=path)
    git("checkout", "--quiet", "--detach", commit, cwd=path)


def preflight(worktree, settings, env):
    if not settings["DEVELOPMENT_TEAM"] or settings["CODESIGN_IDENTITY"] in ("", "-"):
        raise ValueError("Set DEVELOPMENT_TEAM and a Developer ID CODESIGN_IDENTITY (see docs/releasing.md).")
    pinned = (worktree / ".swift-version").read_text().strip()
    for args in (["/bin/bash", "-c", "source script/setup.sh; swift --version"], ["xcrun", "swift", "--version"]):
        output = command(*args, cwd=worktree, env=env)
        if not re.search(rf"Swift version {re.escape(pinned)}(?:\s|$)", output):
            raise ValueError(f"{' '.join(args[-2:])} isn't the pinned Swift {pinned}; set TOOLCHAINS in {SETTINGS_FILE}.")
    command(sys.executable, "-B", "script/sign-sparkle-update.py", "--check-credentials", cwd=worktree, env=env)
    command(sys.executable, "-B", "script/check-signing-keychain.py", cwd=worktree, env=env)


def start(args):
    settings = load_settings()
    source = Path(git("rev-parse", "--show-toplevel"))
    if args.commit == "HEAD":
        changed = git("status", "--porcelain", "--untracked-files=no", cwd=source)
        if changed:
            raise ValueError(f"Commit or stash tracked changes first; the release builds the committed HEAD:\n{changed}")
    commit = git("rev-parse", "--verify", f"{args.commit}^{{commit}}", cwd=source)
    git("fetch", "--quiet", "origin", BRANCH, cwd=source)
    tip = git("rev-parse", f"origin/{BRANCH}", cwd=source)
    state = relation(commit, tip, lambda a, b: is_ancestor(a, b, source))
    if state == "behind":
        raise ValueError(f"{commit[:8]} is already in {BRANCH} but isn't its tip {tip[:8]}; previews publish the tip "
                         f"(`make ship COMMIT=origin/{BRANCH}`).")
    if state == "diverged":
        raise ValueError(f"{commit[:8]} has diverged from origin/{BRANCH}; rebase onto it first.")

    worktree = Path(settings["WINMUX_RELEASE_WORKTREE"]).expanduser()
    common_dir = Path(git("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=source))
    run_id = time.strftime("%Y%m%d-%H%M%S") + f"-{commit[:8]}"
    run_dir = runs_root(settings) / run_id
    lock = ShipLock(common_dir / "winmux-ship.lock")

    def run_status(owner):
        try:
            return json.loads((runs_root(settings) / owner["run"] / "status.json").read_text())["state"]
        except (OSError, ValueError, KeyError, TypeError):
            return None

    lock.acquire(run_id, run_status)
    try:
        env = release_environment(os.environ, settings)
        prepare_worktree(worktree, commit, common_dir, source)
        preflight(worktree, settings, env)
        if args.dry_run:
            lock.release(os.getpid())
            action = f"push it to {BRANCH} and release it" if state == "ahead" else "release it"
            print(f"Ready: `make ship` would {action} ({commit[:8]}) from {worktree}.")
            return 0
        if state == "ahead":
            git("push", "--quiet", "origin", f"{commit}:refs/heads/{BRANCH}", cwd=source)
        run_dir.mkdir(parents=True)
        (run_dir / "request.json").write_text(json.dumps({
            "commit": commit, "worktree": str(worktree), "lock": str(lock.path), "starter": os.getpid(),
            "settings": settings,
        }, indent=2))
        Status.create(run_dir, run=run_id, commit=commit, log=str(run_dir / "log.txt"), pid=None)
        (run_dir.parent / "latest").write_text(run_id + "\n")
        with (run_dir / "runner.log").open("w") as runner_log:
            runner = subprocess.Popen([sys.executable, "-B", str(worktree / "script/ship.py"), "run", str(run_dir)],
                                      cwd=worktree, env=env, stdin=subprocess.DEVNULL, stdout=runner_log,
                                      stderr=subprocess.STDOUT, start_new_session=True)
        lock.hand_over(runner.pid, run_id)
    except BaseException:
        lock.release(os.getpid())
        raise
    pushed = f", pushed to {BRANCH}" if state == "ahead" else ""
    print(f"Started the preview release of {commit[:8]}{pushed} (run {run_id}).\n"
          f"Wait:   make ship-wait    (prints the summary; exits 0 when published, 1 on failure)\n"
          f"Status: make ship-status\n"
          f"Log:    {run_dir / 'log.txt'}")
    return 0


def run_release(args):
    run_dir = Path(args.run_dir)
    request = json.loads((run_dir / "request.json").read_text())
    status = Status(run_dir)
    tracker = PhaseTracker(status)
    lock = ShipLock(request["lock"])
    process = None

    def stop(signum, _frame):
        raise SystemExit(f"Stopped by signal {signum}.")

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGHUP, stop)
    try:
        status.update(state="running", pid=os.getpid())
        settings = request["settings"]
        # Tests replace the command.
        release_command = request.get("command") or [
            "make", "prerelease-local", f"CODESIGN_IDENTITY={settings['CODESIGN_IDENTITY']}",
            f"DEVELOPMENT_TEAM={settings['DEVELOPMENT_TEAM']}", f"NOTARYTOOL_KEYCHAIN={settings['NOTARYTOOL_KEYCHAIN']}"]
        with open(status.data["log"], "w") as log:
            process = subprocess.Popen(release_command, cwd=request["worktree"], stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True, errors="replace", bufsize=1)
            try:
                for line in process.stdout:
                    log.write(line)
                    log.flush()
                    tracker.observe(line)
                code = process.wait()
            finally:
                process.stdout.close()
        if code:
            status.finish("failed", error_excerpt(tracker.recent))
        elif not status.data["tag"]:
            status.finish("failed", ["The release ended without reporting its tag."] + error_excerpt(tracker.recent))
        else:
            tracker.enter("verify")
            tag = status.data["tag"]
            checks = verify_release(tag, request["commit"],
                                    Path(request["worktree"]) / ".local/prereleases" / tag)
            status.update(url=status.data["url"] or f"https://github.com/{preview.REPOSITORY}/releases/tag/{tag}")
            status.finish("succeeded" if all(check["ok"] for check in checks) else "failed", checks=checks)
    except BaseException as error:
        if process and process.poll() is None:
            process.terminate()
        status.finish("failed", [str(error) or type(error).__name__] + error_excerpt(tracker.recent)[-4:])
    finally:
        summary = summarize(status.data)
        (run_dir / "summary.txt").write_text(summary)
        try:
            notify(status.data, summary, request["settings"])
        except (OSError, subprocess.SubprocessError):
            pass
        # The starter may not have handed the lock over yet.
        lock.release(os.getpid(), request["starter"])
    return 0 if status.data["state"] == "succeeded" else 1


def wait(args, sleep=time.sleep, clock=time.monotonic):
    settings = load_settings() if args.settings is None else args.settings
    run_dir = find_run(settings, args.run)
    deadline = clock() + args.timeout * 60
    announced = False
    while True:
        data = json.loads((run_dir / "status.json").read_text())
        if data["state"] in TERMINAL:
            summary = run_dir / "summary.txt"
            print(summary.read_text() if summary.exists() else summarize(data), end="")
            return 0 if data["state"] == "succeeded" else 1
        stalled = data["pid"] is None and time.time() - data["started"] > 60
        if stalled or (data["pid"] is not None and not pid_alive(data["pid"])):
            if json.loads((run_dir / "status.json").read_text())["state"] in TERMINAL:
                continue
            log = Path(data["log"])
            tail = log.read_text(errors="replace").splitlines() if log.exists() else []
            print(f"The release runner stopped during {data['phase']} without finishing (run {run_dir.name}).")
            print("\n".join(f"  {line}" for line in error_excerpt(tail)))
            print(f"Log: {log}")
            return 1
        if clock() >= deadline:
            elapsed = duration(time.time() - data["started"])
            print(f"Still running: {data['phase']} after {elapsed} (run {run_dir.name}); wait again with `make ship-wait`.")
            return 2
        if not announced:
            print(f"Waiting for release {run_dir.name} ({data['phase']})...", flush=True)
            announced = True
        sleep(args.interval)


def status_line(args):
    settings = load_settings()
    run_dir = find_run(settings, args.run)
    data = json.loads((run_dir / "status.json").read_text())
    if data["state"] in TERMINAL:
        print(summarize(data).splitlines()[0])
    else:
        alive = "" if data["pid"] is None or pid_alive(data["pid"]) else ", runner not running"
        print(f"Release {run_dir.name}: {data['state']}, {data['phase']} after "
              f"{duration(time.time() - data['started'])}{alive}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="Publish a local preview unattended.")
    commands = parser.add_subparsers(dest="command", required=True)
    start_parser = commands.add_parser("start", help="check, push, and start a preview release")
    start_parser.add_argument("--commit", default="HEAD")
    start_parser.add_argument("--dry-run", action="store_true", help="check and preflight only")
    run_parser = commands.add_parser("run", help=argparse.SUPPRESS)
    run_parser.add_argument("run_dir")
    wait_parser = commands.add_parser("wait", help="wait for a release and print its summary")
    wait_parser.add_argument("run", nargs="?")
    wait_parser.add_argument("--timeout", type=float, default=60, help="minutes (default 60)")
    wait_parser.add_argument("--interval", type=float, default=5, help=argparse.SUPPRESS)
    wait_parser.set_defaults(settings=None)
    status_parser = commands.add_parser("status", help="one line about a release")
    status_parser.add_argument("run", nargs="?")
    args = parser.parse_args(argv)
    handlers = {"start": start, "run": run_release, "wait": wait, "status": status_line}
    return handlers[args.command](args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
