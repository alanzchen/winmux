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
import tempfile
import hashlib
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


def pinned_swift_version_pattern(pinned):
    """Matches `swift --version` output for the pinned MAJOR.MINOR.PATCH, which prints an X.Y.0 release as X.Y."""
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", pinned):
        raise ValueError(f".swift-version must be MAJOR.MINOR.PATCH, not {pinned!r}.")
    versions = {pinned, re.sub(r"^([0-9]+\.[0-9]+)\.0$", r"\1", pinned)}
    return rf"Swift version (?:{'|'.join(re.escape(version) for version in sorted(versions))})(?:\s|$)"


def preview_version(prefix, tags):
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", prefix):
        raise ValueError("The prerelease version prefix must be MAJOR.MINOR.")
    versions = []
    for tag in tags:
        try:
            version = release.version_tuple(tag)
        except ValueError:
            continue
        if version[:2] == tuple(map(int, prefix.split("."))):
            versions.append(version[2])
    return f"{prefix}.{max(versions, default=0) + 1}"


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


def local_branch():
    # A dedicated release worktree checks the commit out detached and names its branch instead.
    branch = release.run("git", "branch", "--show-current") or os.environ.get("RELEASE_BRANCH", "")
    if branch not in BRANCHES:
        raise ValueError("Local previews must come from an integration branch.")
    return branch


def check_context(local=False):
    if local:
        local_branch()
        return release.run("git", "rev-parse", "HEAD")
    if os.environ.get("GITHUB_REPOSITORY") != REPOSITORY:
        raise ValueError("Prereleases are restricted to the configured fork.")
    if os.environ.get("GITHUB_REF") not in {f"refs/heads/{branch}" for branch in BRANCHES}:
        raise ValueError("Only integration branches can publish prereleases.")
    if os.environ.get("GITHUB_SHA") != release.run("git", "rev-parse", "HEAD"):
        raise ValueError("Checkout does not match the triggering commit.")
    return os.environ["GITHUB_SHA"]


def published_for_commit(commit):
    refs = api("git/matching-refs/tags/v") or []
    tags = {ref["ref"].removeprefix("refs/tags/") for ref in refs
            if ref["object"]["type"] == "commit" and ref["object"]["sha"] == commit}
    records = []
    for record in release.read_releases(REPOSITORY):
        if record["tag_name"] not in tags or record["draft"] or not record["prerelease"]:
            continue
        try:
            release.version_tuple(record["tag_name"])
        except ValueError:
            continue
        records.append(record)
    return max(records, key=lambda item: release.version_tuple(item["tag_name"]), default=None)


def prepare(local=False):
    commit = check_context(local=local)
    published = published_for_commit(commit)
    if published:
        repair_published_feed(published)
        if not local:
            with open(os.environ["GITHUB_ENV"], "a") as output:
                output.write("SKIP_RELEASE=true\n")
        print(f"Already published: https://github.com/{REPOSITORY}/releases/tag/{published['tag_name']}")
        return published["tag_name"], True
    prefix = Path(".prerelease-version").read_text().strip()
    # The atomic ref creation coordinates local and hosted builds without sharing credentials.
    for attempt in range(5):
        refs = api("git/matching-refs/tags/v") or []
        version = preview_version(prefix, [ref["ref"].removeprefix("refs/tags/") for ref in refs])
        tag = f"v{version}"
        check_order(tag, release.read_releases(REPOSITORY))
        try:
            api("git/refs", "POST", {"ref": f"refs/tags/{tag}", "sha": commit})
            break
        except ValueError:
            if attempt == 4 or api(f"git/ref/tags/{tag}") is None:
                raise
    release.run("git", "fetch", "origin", f"refs/tags/{tag}:refs/tags/{tag}")
    release.check_tag(tag, REPOSITORY, allowed_branches=BRANCHES)
    if not local:
        with open(os.environ["GITHUB_ENV"], "a") as output:
            output.write(f"VERSION={version}\nRELEASE_TAG={tag}\nSKIP_RELEASE=false\n")
    print(f"Prepared {tag} from {commit}.")
    return tag, False


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
        api("git/refs", "POST", {"ref": f"refs/heads/{FEED_BRANCH}", "sha": release.run("git", "rev-parse", "HEAD")})
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


def repair_published_feed(published):
    tag = published["tag_name"]
    try:
        check_order(tag, release.read_releases(REPOSITORY), allow_current=True)
    except ValueError:
        # A newer release has superseded this commit; do not roll back its feed.
        return
    asset = next((asset for asset in published["assets"] if asset["name"] == "appcast.xml"), None)
    if asset is None:
        raise ValueError("Published preview is missing its appcast.")
    with tempfile.TemporaryDirectory(prefix="winmux-feed-repair-") as directory:
        release.run("gh", "release", "download", tag, "--repo", REPOSITORY,
                    "--pattern", "appcast.xml", "--dir", directory)
        path = Path(directory) / "appcast.xml"
        if asset.get("digest") != "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest():
            raise ValueError("Published appcast checksum does not match GitHub.")
        appcast.validate_appcast(path, tag[1:],
                                f"https://github.com/{REPOSITORY}/releases/download/{tag}/WinMux-{tag[1:]}.zip")
        advance_feed(tag, path)


def publish(local=False):
    commit = check_context(local=local)
    published = published_for_commit(commit)
    if published:
        repair_published_feed(published)
        print(f"This commit is already published: https://github.com/{REPOSITORY}/releases/tag/{published['tag_name']}")
        return published["tag_name"]
    tag = os.environ["RELEASE_TAG"]
    directory = Path(os.environ.get("RELEASE_DIR", ".release"))
    paths = release.release_assets(tag, directory)
    release.check_tag(tag, REPOSITORY, allowed_branches=BRANCHES)
    appcast.validate_appcast(directory / "appcast.xml", tag[1:],
                            f"https://github.com/{REPOSITORY}/releases/download/{tag}/WinMux-{tag[1:]}.zip",
                            directory / f"WinMux-{tag[1:]}.zip", require_arm64=True)
    draft = check_order(tag, release.read_releases(REPOSITORY))
    if draft is None:
        # Use the creation response: the releases list can briefly omit a new draft.
        draft = api("releases", "POST", {
            "tag_name": tag, "name": f"WinMux {tag[1:]} Preview", "draft": True,
            "prerelease": True, "make_latest": "false", "generate_release_notes": True,
        })
    if not draft or not draft["draft"] or draft["tag_name"] != tag:
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
    return tag


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
