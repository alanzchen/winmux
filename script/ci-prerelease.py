#!/usr/bin/env python3
"""Publish immutable signed previews and atomically advance their Sparkle feed."""

import base64
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load_module("ci_release", "ci-release.py")
appcast = load_module("validate_appcast", "validate-appcast.py")
REPOSITORY = "alanzchen/winmux"
BRANCHES = ("main", "codex/issue-fixes")
FEED_BRANCH = "updates"
FEED_PATH = "prerelease.xml"


def preview_version(prefix, run_number, attempt):
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", prefix):
        raise ValueError("The prerelease version prefix must be MAJOR.MINOR.")
    if run_number < 1 or not 1 <= attempt < 100:
        raise ValueError("Invalid run number or attempt; at most 99 attempts are supported.")
    # A retry gets a fresh immutable version; later runs always compare newer.
    return f"{prefix}.{(run_number - 1) * 100 + attempt}"


def check_order(tag, records, allow_current=False):
    requested = release.version_tuple(tag)
    draft = None
    for record in records:
        if record["tag_name"] == tag:
            if not record["draft"] and not allow_current:
                raise ValueError(f"{tag} is already published; never replace its signed assets.")
            draft = record if record["draft"] else None
        if record["draft"]:
            continue
        try:
            existing = release.version_tuple(record["tag_name"])
        except ValueError:
            continue
        if existing > requested or (existing == requested and not allow_current):
            raise ValueError("A newer or equal release already exists; refusing a stale preview.")
    return draft


def api(path, method="GET", data=None):
    args = ["gh", "api", f"repos/{REPOSITORY}/{path}", "--method", method]
    if data is not None:
        args += ["--input", "-"]
    result = subprocess.run(args, input=json.dumps(data) if data is not None else None,
                            text=True, capture_output=True)
    if result.returncode:
        # Only a missing object is optional; authorization and network errors must fail.
        if method == "GET" and "HTTP 404" in result.stderr:
            return None
        raise ValueError(f"GitHub API {method} {path} failed: {result.stderr.strip()}")
    return json.loads(result.stdout) if result.stdout.strip() else None


def check_context():
    if os.environ.get("GITHUB_REPOSITORY") != REPOSITORY:
        raise ValueError("Prereleases are restricted to the configured fork.")
    if os.environ.get("GITHUB_REF") not in {f"refs/heads/{branch}" for branch in BRANCHES}:
        raise ValueError("Only integration branch pushes can publish prereleases.")
    if os.environ.get("GITHUB_SHA") != release.run("git", "rev-parse", "HEAD"):
        raise ValueError("Checkout does not match the triggering commit.")


def prepare():
    check_context()
    version = preview_version(Path(".prerelease-version").read_text().strip(),
                              int(os.environ["GITHUB_RUN_NUMBER"]), int(os.environ["GITHUB_RUN_ATTEMPT"]))
    tag = f"v{version}"
    check_order(tag, release.read_releases(REPOSITORY))
    commit = os.environ["GITHUB_SHA"]
    existing = api(f"git/ref/tags/{tag}")
    if existing is None:
        api("git/refs", "POST", {"ref": f"refs/tags/{tag}", "sha": commit})
    elif existing["object"]["sha"] != commit:
        raise ValueError("Prerelease tag already identifies another commit.")
    release.run("git", "fetch", "origin", f"refs/tags/{tag}:refs/tags/{tag}")
    release.check_tag(tag, REPOSITORY, allowed_branches=BRANCHES)
    with open(os.environ["GITHUB_ENV"], "a") as output:
        output.write(f"VERSION={version}\nRELEASE_TAG={tag}\n")
    print(f"Prepared {tag} from {commit}.")


def check_feed_order(current_xml, version):
    items = ET.fromstring(current_xml).findall("./channel/item")
    if len(items) != 1:
        raise ValueError("The current preview feed is malformed.")
    current = items[0].findtext(appcast.SPARKLE + "version")
    if release.version_tuple(f"v{current}") > release.version_tuple(f"v{version}"):
        raise ValueError("Refusing to move the preview feed backwards.")


def advance_feed(tag, path):
    # The archive is already public and immutable before its feed is made visible.
    check_order(tag, release.read_releases(REPOSITORY), allow_current=True)
    published = api(f"releases/tags/{tag}")
    if not published or published["draft"] or not published["prerelease"]:
        raise ValueError("Only a published prerelease can enter the preview feed.")
    if api(f"git/ref/heads/{FEED_BRANCH}") is None:
        api("git/refs", "POST", {"ref": f"refs/heads/{FEED_BRANCH}", "sha": os.environ["GITHUB_SHA"]})
    current = api(f"contents/{FEED_PATH}?ref={FEED_BRANCH}")
    payload = {
        "message": f"Update preview feed to {tag}",
        "content": base64.b64encode(path.read_bytes()).decode(),
        "branch": FEED_BRANCH,
    }
    if current:
        existing = base64.b64decode(current["content"])
        check_feed_order(existing, tag[1:])
        if existing == path.read_bytes():
            return
        # Compare-and-swap: concurrent changes fail instead of replacing another feed.
        payload["sha"] = current["sha"]
    api(f"contents/{FEED_PATH}", "PUT", payload)


def publish():
    check_context()
    tag = os.environ["RELEASE_TAG"]
    directory = Path(os.environ.get("RELEASE_DIR", ".release"))
    paths = release.release_assets(tag, directory)
    release.check_tag(tag, REPOSITORY, allowed_branches=BRANCHES)
    appcast.validate_appcast(directory / "appcast.xml", tag[1:],
                            f"https://github.com/{REPOSITORY}/releases/download/{tag}/WinMux-{tag[1:]}.zip",
                            directory / f"WinMux-{tag[1:]}.zip")
    draft = check_order(tag, release.read_releases(REPOSITORY))
    if draft is None:
        release.run("gh", "release", "create", tag, "--repo", REPOSITORY, "--verify-tag", "--draft",
                    "--prerelease", "--latest=false", "--title", f"WinMux {tag[1:]} Preview", "--generate-notes")
        draft = check_order(tag, release.read_releases(REPOSITORY))
    if draft is None:
        raise ValueError("GitHub did not return the prerelease draft.")
    for asset in draft["assets"]:
        release.run("gh", "release", "delete-asset", tag, asset["name"], "--repo", REPOSITORY, "--yes")
    release.run("gh", "release", "upload", tag, *(str(path) for path in paths), "--repo", REPOSITORY)
    uploaded = api(f"releases/{draft['id']}")
    if not uploaded["draft"]:
        raise ValueError("Another process published this draft during upload.")
    release.verify_uploaded_assets(paths, uploaded["assets"])
    release.check_tag(tag, REPOSITORY, allowed_branches=BRANCHES)
    check_order(tag, release.read_releases(REPOSITORY))
    release.run("gh", "release", "edit", tag, "--repo", REPOSITORY,
                "--draft=false", "--prerelease=true", "--latest=false")
    advance_feed(tag, directory / "appcast.xml")
    print(f"Published preview https://github.com/{REPOSITORY}/releases/tag/{tag} and advanced the feed.")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["prepare"]:
            prepare()
        elif sys.argv[1:] == ["publish"]:
            publish()
        else:
            raise ValueError("Usage: ci-prerelease.py prepare|publish")
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
