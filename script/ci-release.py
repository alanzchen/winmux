#!/usr/bin/env python3
"""Validate immutable release tags and publish a complete, verified draft."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def version_tuple(tag):
    match = re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag)
    if not match:
        raise ValueError("Release tags must be stable versions: vMAJOR.MINOR.PATCH.")
    return tuple(map(int, match.groups()))


def check_release_order(tag, releases):
    requested = version_tuple(tag)
    drafts = []
    for release in releases:
        release_tag = release["tag_name"]
        if release_tag == tag:
            if not release["draft"]:
                raise ValueError(f"{tag} is already published; create a new version instead of replacing signed assets.")
            drafts.append(release)
        if release["draft"] or release["prerelease"]:
            continue
        try:
            existing = version_tuple(release_tag)
        except ValueError:
            continue
        if existing >= requested:
            raise ValueError(f"{tag} must be newer than published stable release {release_tag}.")
    if len(drafts) > 1:
        raise ValueError(f"Multiple drafts exist for {tag}; resolve them before publishing.")
    return drafts[0] if drafts else None


def check_tag(tag, repository, allowed_branches=()):
    version_tuple(tag)
    if repository != "alanzchen/winmux":
        raise ValueError("This release pipeline publishes only to alanzchen/winmux.")
    if os.environ.get("GITHUB_ACTIONS") == "true":
        ref = os.environ.get("GITHUB_REF")
        if ref != f"refs/tags/{tag}" and ref not in {f"refs/heads/{branch}" for branch in allowed_branches}:
            raise ValueError("Run this workflow on the same tag ref as its tag input (the release environment allows tags only).")
        if ref != f"refs/tags/{tag}" and os.environ.get("GITHUB_SHA") != run("git", "rev-parse", "HEAD"):
            raise ValueError("The prerelease checkout must match the triggering commit.")
    local_commit = run("git", "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}")
    if local_commit != run("git", "rev-parse", "HEAD"):
        raise ValueError("The checked-out commit does not match the release tag.")
    # Recheck the server before publication, including annotated tags, to catch a moved tag.
    remote = run("git", "ls-remote", "--exit-code", f"https://github.com/{repository}.git",
                 f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}")
    refs = dict(line.split()[::-1] for line in remote.splitlines())
    remote_commit = refs.get(f"refs/tags/{tag}^{{}}", refs.get(f"refs/tags/{tag}"))
    if remote_commit != local_commit:
        raise ValueError("The remote release tag changed or is missing; refusing publication.")


def read_releases(repository):
    pages = json.loads(run("gh", "api", f"repos/{repository}/releases?per_page=100", "--paginate", "--slurp"))
    return [release for page in pages for release in page]


def release_assets(tag, directory):
    version_tuple(tag)
    version = tag[1:]
    names = [f"WinMux-{version}.zip", f"WinMux-{version}-macOS.zip",
             f"WinMux-{version}.dmg", "appcast.xml", "SHA256SUMS"]
    paths = [Path(directory) / name for name in names]
    for path in paths:
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"Missing or empty release asset: {path}")
    return paths


def verify_uploaded_assets(paths, uploaded):
    actual = {asset["name"]: asset for asset in uploaded}
    if len(actual) != len(uploaded) or set(actual) != {path.name for path in paths}:
        raise ValueError("The draft release assets do not exactly match the verified artifacts.")
    for path in paths:
        asset = actual[path.name]
        expected_digest = "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
        if asset["state"] != "uploaded" or asset["size"] != path.stat().st_size or asset.get("digest") != expected_digest:
            raise ValueError(f"GitHub did not confirm the uploaded checksum for {path.name}.")


def publish(tag, repository, directory):
    paths = release_assets(tag, directory)
    # make PUBLISH=1 and Actions share the same safety checks.
    check_tag(tag, repository)
    draft = check_release_order(tag, read_releases(repository))
    if draft is None:
        run("gh", "release", "create", tag, "--repo", repository, "--verify-tag", "--draft",
            "--title", f"WinMux {tag[1:]}", "--generate-notes")
        draft = check_release_order(tag, read_releases(repository))
    if draft is None:
        raise ValueError("GitHub did not return the newly created draft.")
    # A failed prior upload can leave assets behind. Only draft assets may be replaced.
    for asset in draft["assets"]:
        run("gh", "release", "delete-asset", tag, asset["name"], "--repo", repository, "--yes")
    run("gh", "release", "upload", tag, *(str(path) for path in paths), "--repo", repository)
    draft = json.loads(run("gh", "api", f"repos/{repository}/releases/{draft['id']}"))
    if not draft["draft"]:
        raise ValueError("The release was published by another process during upload.")
    verify_uploaded_assets(paths, draft["assets"])
    check_tag(tag, repository)
    check_release_order(tag, read_releases(repository))
    run("gh", "release", "edit", tag, "--repo", repository, "--draft=false", "--prerelease=false", "--latest")
    print(f"Published https://github.com/{repository}/releases/tag/{tag}")


def main():
    if len(sys.argv) not in (4, 5) or sys.argv[1] not in ("check", "publish"):
        raise ValueError("Usage: ci-release.py check|publish TAG REPOSITORY [RELEASE_DIR]")
    command, tag, repository = sys.argv[1:4]
    if command == "check":
        check_tag(tag, repository)
        check_release_order(tag, read_releases(repository))
        print(f"Validated {tag} for {repository}.")
    else:
        publish(tag, repository, sys.argv[4] if len(sys.argv) == 5 else ".release")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
