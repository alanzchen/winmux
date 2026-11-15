#!/usr/bin/env python3
"""Keep WinMux mergeable with upstream AeroSpace.

Every path in the last merged upstream tree has a class in script/upstream/manifest.tsv:

  pristine     byte-identical to upstream
  hooked       upstream lines untouched; only added lines marked WINMUX-HOOK
  forked       WinMux owns the file; upstream changes are ported by hand at each sync
  deleted      WinMux removed it (patterns allowed); merges drop upstream edits automatically
  winmux-only  not an upstream path (the default for any path absent from upstream)

Subcommands: fetch, guard, report, merge, resolve-deleted, finish, manifest, history-join.
See docs/upstream-sync.md for the procedure.
"""

import argparse
import datetime
import fnmatch
import json
import os
from pathlib import Path
import re
import subprocess
import sys

STATE_PATH = "script/upstream/state.json"
MANIFEST_PATH = "script/upstream/manifest.tsv"
CLASSES = ("pristine", "hooked", "forked", "deleted", "winmux-only")
TARGETS = ("", "pristine", "hooked", "forked", "deleted")
HOOK_MARK = "WINMUX-HOOK"
HOOK_BEGIN = "WINMUX-HOOK-BEGIN"
HOOK_END = "WINMUX-HOOK-END"
MOVED_PREFIX = "moved-to="
RERERE = ("-c", "rerere.enabled=true", "-c", "rerere.autoUpdate=true")
MANIFEST_HEADER = """\
# WinMux upstream file classification. Managed by script/upstream-sync.py; see docs/upstream-sync.md.
# Columns (tab-separated): class, path or glob, target class, note.
# class: pristine | hooked | forked | deleted | winmux-only. Globs are allowed for deleted and winmux-only.
# Any path absent from the upstream base and not matched here is winmux-only.
# target: the class this file should reach by the end of the upstream-sync plan (empty = same as class).
# note: free text; "moved-to=<path>" on a deleted row means the upstream content now lives at <path>.
"""


class UsageError(Exception):
    pass


def git(repo, *args, check=True, strip=True, env=None):
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, env=env)
    if check and result.returncode != 0:
        raise UsageError(f"git {' '.join(args)} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout.strip() if strip else result.stdout


def git_ok(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True).returncode == 0


def repo_root(start="."):
    return Path(git(start, "rev-parse", "--show-toplevel"))


def load_state(repo):
    return json.loads((Path(repo) / STATE_PATH).read_text())


def save_state(repo, state):
    (Path(repo) / STATE_PATH).write_text(json.dumps(state, indent=2) + "\n")


def has_commit(repo, rev):
    return git_ok(repo, "cat-file", "-e", f"{rev}^{{commit}}")


def require_commit(repo, rev, what):
    if not has_commit(repo, rev):
        raise UsageError(f"{what} {rev} is not in this repository; run `script/upstream-sync.py fetch` first.")


def upstream_ref(state, override=None):
    return override or os.environ.get("WINMUX_UPSTREAM_REF") or state["upstream_ref"]


def tree_blobs(repo, rev):
    """Map path -> (mode, object id) for every file in rev."""
    blobs = {}
    for entry in git(repo, "ls-tree", "-r", "-z", "--full-tree", rev, strip=False).split("\0"):
        if not entry:
            continue
        meta, path = entry.split("\t", 1)
        mode, _, oid = meta.split(" ")
        blobs[path] = (mode, oid)
    return blobs


# ---------------------------------------------------------------- manifest

def is_pattern(path):
    return any(ch in path for ch in "*?[")


class Manifest:
    def __init__(self, rows):
        self.rows = rows  # list of dicts: cls, path, target, note
        self.exact = {}
        self.patterns = []
        for row in rows:
            if row["cls"] not in CLASSES:
                raise UsageError(f"manifest: unknown class {row['cls']!r} for {row['path']}")
            if row["target"] not in TARGETS:
                raise UsageError(f"manifest: unknown target {row['target']!r} for {row['path']}")
            if is_pattern(row["path"]):
                if row["cls"] not in ("deleted", "winmux-only"):
                    raise UsageError(f"manifest: globs are only allowed for deleted/winmux-only: {row['path']}")
                self.patterns.append(row)
            else:
                if row["path"] in self.exact:
                    raise UsageError(f"manifest: duplicate path {row['path']}")
                self.exact[row["path"]] = row

    @staticmethod
    def parse(text):
        rows = []
        for number, line in enumerate(text.splitlines(), 1):
            if not line.strip() or line.startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) < 2:
                raise UsageError(f"manifest line {number}: expected tab-separated class and path")
            fields += [""] * (4 - len(fields))
            rows.append({"cls": fields[0].strip(), "path": fields[1].strip(),
                         "target": fields[2].strip(), "note": fields[3].strip()})
        return Manifest(rows)

    @staticmethod
    def load(repo, rev=None):
        if rev:
            return Manifest.parse(git(repo, "show", f"{rev}:{MANIFEST_PATH}", strip=False))
        return Manifest.parse((Path(repo) / MANIFEST_PATH).read_text())

    def row(self, path):
        if path in self.exact:
            return self.exact[path]
        for row in self.patterns:
            if fnmatch.fnmatchcase(path, row["path"]):
                return row
        return None

    def cls(self, path):
        row = self.row(path)
        return row["cls"] if row else None

    def moved_to(self, path):
        row = self.row(path)
        if row and row["note"].startswith(MOVED_PREFIX):
            return row["note"][len(MOVED_PREFIX):].split()[0]
        return None

    def render(self):
        def key(row):
            return (is_pattern(row["path"]), row["path"])
        lines = [MANIFEST_HEADER]
        for row in sorted(self.rows, key=key):
            lines.append("\t".join([row["cls"], row["path"], row["target"], row["note"]]).rstrip("\t") + "\n")
        return "".join(lines)

    def save(self, repo):
        (Path(repo) / MANIFEST_PATH).write_text(self.render())


def classify_path(path, base, head):
    if path not in head:
        return "deleted"
    if head[path] == base[path]:
        return "pristine"
    return "forked"


def update_manifest(repo, manifest, base_rev, head_rev="HEAD"):
    """Add rows for unclassified upstream paths, drop exact rows for paths upstream removed.

    Returns (added, dropped, reclassified) path lists. A pristine row whose file changed becomes forked,
    and a forked row whose file matches upstream again becomes pristine, so the manifest describes HEAD.
    """
    base = tree_blobs(repo, base_rev)
    head = tree_blobs(repo, head_rev)
    rows, added, dropped, reclassified = [], [], [], []
    for row in manifest.rows:
        path = row["path"]
        if not is_pattern(path) and row["cls"] != "winmux-only" and path not in base:
            dropped.append(path)
            continue
        if not is_pattern(path) and path in base and row["cls"] in ("pristine", "forked", "deleted"):
            actual = classify_path(path, base, head)
            if actual != row["cls"]:
                reclassified.append((path, row["cls"], actual))
                row = dict(row, cls=actual)
        rows.append(row)
    current = Manifest(rows)
    for path in sorted(base):
        if current.row(path) is None:
            cls = classify_path(path, base, head)
            rows.append({"cls": cls, "path": path, "target": "", "note": ""})
            added.append(path)
    return Manifest(rows), added, dropped, reclassified


# ---------------------------------------------------------------- guard

def hooked_violations(repo, base_rev, head_rev, path):
    diff = git(repo, "diff", "-U0", "--no-color", "--no-ext-diff", base_rev, head_rev, "--", path, strip=False)
    problems, in_block = [], False
    for line in diff.splitlines():
        if line.startswith(("---", "+++", "diff ", "index ", "@@")):
            continue
        if line.startswith("Binary files"):
            problems.append("binary change")
        elif line.startswith("-"):
            problems.append(f"removes or edits upstream line: {line[1:].strip()[:100]}")
        elif line.startswith("+"):
            text = line[1:]
            if HOOK_BEGIN in text:
                in_block = True
            elif HOOK_END in text:
                in_block = False
            elif not in_block and HOOK_MARK not in text:
                problems.append(f"unmarked added line: {text.strip()[:100]}")
    if in_block:
        problems.append(f"{HOOK_BEGIN} without {HOOK_END}")
    return problems


def is_budgeted(path):
    return path.startswith("Sources/") and "Tests/" not in path


def guard(repo, rev="HEAD"):
    """Return (errors, warnings, summary)."""
    state = load_state(repo)
    base_rev = state["upstream_base"]
    require_commit(repo, base_rev, "upstream base")
    manifest = Manifest.load(repo, rev)
    base = tree_blobs(repo, base_rev)
    head = tree_blobs(repo, rev)
    errors, warnings = [], []
    counts = {cls: 0 for cls in CLASSES}
    for path in sorted(base):
        row = manifest.row(path)
        cls = row["cls"] if row else None
        if cls is None:
            errors.append((path, "upstream path is not classified in the manifest"))
            continue
        counts[cls] += 1
        if cls == "winmux-only":
            errors.append((path, "upstream path is classified winmux-only"))
        elif cls == "pristine":
            if path not in head:
                errors.append((path, "pristine file is missing (classify it deleted)"))
            elif head[path] != base[path]:
                errors.append((path, "pristine file differs from upstream"))
        elif cls == "hooked":
            if path not in head:
                errors.append((path, "hooked file is missing"))
            else:
                for problem in hooked_violations(repo, base_rev, rev, path):
                    errors.append((path, f"hooked: {problem}"))
        elif cls == "forked":
            if path not in head:
                errors.append((path, "forked file is missing (classify it deleted)"))
            elif head[path] == base[path]:
                warnings.append((path, "forked file is identical to upstream (classify it pristine)"))
        elif cls == "deleted" and path in head:
            errors.append((path, "deleted upstream path exists in WinMux"))
    winmux_only = 0
    for path in sorted(set(head) - set(base)):
        row = manifest.row(path)
        cls = row["cls"] if row else "winmux-only"
        if cls in ("pristine", "hooked", "forked"):
            errors.append((path, f"classified {cls} but not an upstream path"))
        elif cls == "deleted":
            errors.append((path, f"matches deleted pattern {row['path']}"))
        else:
            winmux_only += 1
    for path, row in manifest.exact.items():
        if path not in base and row["cls"] != "winmux-only":
            errors.append((path, "manifest row for a path that is not in the upstream base"))
    budget = state.get("forked_budget")
    forked_sources = sorted(p for p, r in manifest.exact.items() if r["cls"] == "forked" and is_budgeted(p))
    if budget is not None and len(forked_sources) > budget:
        warnings.append(("(budget)", f"{len(forked_sources)} forked non-test Sources files; target is <= {budget}"))
    targets = {}
    for row in manifest.exact.values():
        if row["target"] and row["target"] != row["cls"]:
            targets[(row["cls"], row["target"])] = targets.get((row["cls"], row["target"]), 0) + 1
    summary = {"upstream_base": base_rev, "rev": rev, "counts": counts, "winmux_only_files": winmux_only,
               "forked_sources": len(forked_sources), "pending_transitions": targets}
    return errors, warnings, summary


def print_guard(errors, warnings, summary, out=None, limit=None):
    out = out or sys.stdout
    counts = summary["counts"]
    print(f"upstream base {summary['upstream_base'][:12]}, checked {summary['rev']}", file=out)
    print("classes: " + ", ".join(f"{cls} {counts[cls]}" for cls in CLASSES if cls != "winmux-only")
          + f"; winmux-only files {summary['winmux_only_files']}", file=out)
    print(f"forked non-test Sources files: {summary['forked_sources']}", file=out)
    if summary["pending_transitions"]:
        print("planned transitions: " + ", ".join(
            f"{a}->{b} {n}" for (a, b), n in sorted(summary["pending_transitions"].items())), file=out)
    for label, items in (("ERROR", errors), ("WARN", warnings)):
        shown = items if limit is None else items[:limit]
        for path, message in shown:
            print(f"{label} {path}: {message}", file=out)
        if len(shown) < len(items):
            print(f"{label} ... {len(items) - len(shown)} more", file=out)
    print(f"{len(errors)} error(s), {len(warnings)} warning(s)", file=out)


# ---------------------------------------------------------------- report

ACTIONS = {
    "pristine": "merges as is",
    "hooked": "merges; re-check WINMUX-HOOK lines",
    "forked": "PORT BY HAND: review the upstream diff",
    "deleted": "auto-resolved: stays deleted",
    "winmux-only": "COLLISION: upstream now has this path",
    None: "unclassified",
}


def conflicts(repo, base_rev, ours, theirs):
    """Dry-run merge with an explicit base; returns list of (type, path)."""
    result = subprocess.run(["git", "-C", str(repo), "merge-tree", "--write-tree", "--name-only",
                             f"--merge-base={base_rev}", ours, theirs], capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise UsageError(f"git merge-tree failed: {result.stderr.strip()}")
    found = []
    for line in result.stdout.splitlines():
        match = re.match(r"CONFLICT \(([^)]*)\): (.*)", line)
        if not match:
            continue
        kind, rest = match.groups()
        if rest.startswith("Merge conflict in "):
            path = rest[len("Merge conflict in "):]
        else:
            path = rest.split(" ")[0]
        found.append((kind, path))
    return found


def upstream_changes(repo, base_rev, target):
    changes = []
    numstat = {}
    for line in git(repo, "diff", "--numstat", "--no-renames", base_rev, target).splitlines():
        added, deleted, path = line.split("\t", 2)
        numstat[path] = (added, deleted)
    for line in git(repo, "diff", "--name-status", "-M50%", base_rev, target).splitlines():
        fields = line.split("\t")
        status = fields[0][0]
        old = fields[1]
        new = fields[2] if len(fields) > 2 else fields[1]
        changes.append((status, old, new, numstat.get(new, numstat.get(old, ("?", "?")))))
    return changes


def conflict_classifier(repo, manifest, base_rev, target, head="HEAD"):
    """Return a function path -> class label for merge conflicts between head and target."""
    head_paths = set(tree_blobs(repo, head))
    renamed_from = {new: old for status, old, new, _ in upstream_changes(repo, base_rev, target) if status == "R"}
    moved_into = {manifest.moved_to(row["path"]): row["path"] for row in manifest.rows if manifest.moved_to(row["path"])}

    def classify(path):
        origin = renamed_from.get(path, path)
        row = manifest.row(origin)
        if row and row["cls"] != "winmux-only":
            cls = row["cls"]
            if cls == "deleted" and manifest.moved_to(origin):
                return "deleted, moved: port by hand"
            return cls if origin == path else f"{cls} (renamed upstream)"
        if path in moved_into:
            return "moved (WinMux copy of an upstream file)"
        if path in head_paths:
            return "winmux-only collision"
        return "new"
    return classify


def report(repo, target, head="HEAD", with_conflicts=True):
    state = load_state(repo)
    base_rev = state["upstream_base"]
    require_commit(repo, base_rev, "upstream base")
    require_commit(repo, target, "upstream ref")
    manifest = Manifest.load(repo)
    head_paths = set(tree_blobs(repo, head))
    target_sha = git(repo, "rev-parse", target)
    commits = git(repo, "log", "--no-merges", "--reverse", "--date=short", "--format=%h\t%ad\t%s",
                  f"{base_rev}..{target}").splitlines()
    lines = [f"# Upstream sync report\n",
             f"- upstream base (last merged): `{base_rev[:12]}`",
             f"- upstream target: `{target}` = `{target_sha[:12]}`",
             f"- WinMux: `{head}` = `{git(repo, 'rev-parse', '--short=12', head)}`",
             f"- generated: {datetime.date.today().isoformat()}",
             f"- upstream commits since base: {len(commits)}", ""]
    groups = {}
    for status, old, new, (added, deleted) in upstream_changes(repo, base_rev, target):
        if status == "A":
            row = manifest.row(new)
            if new in head_paths:
                cls, action = "winmux-only", ACTIONS["winmux-only"]
            elif row and row["cls"] == "deleted":
                cls, action = "deleted", "auto-resolved: new file under a deleted pattern is dropped"
            else:
                cls, action = "new", "new upstream file: becomes pristine"
        else:
            cls = manifest.cls(old)
            action = ACTIONS.get(cls, ACTIONS[None])
            moved = manifest.moved_to(old)
            if cls == "deleted" and moved:
                action = f"PORT BY HAND to `{moved}` (WinMux moved this file)"
            if status == "D":
                action += "; upstream deleted it"
            elif status == "R":
                action += f"; upstream renamed it to `{new}`"
        groups.setdefault(cls or "unclassified", []).append((status, old, new, added, deleted, action))
    lines.append("## Upstream file changes by WinMux class\n")
    order = ["forked", "hooked", "winmux-only", "unclassified", "deleted", "pristine", "new"]
    for cls in order + sorted(set(groups) - set(order)):
        if cls not in groups:
            continue
        entries = groups[cls]
        lines.append(f"### {cls} ({len(entries)})\n")
        lines.append("| status | path | +/- | action |")
        lines.append("|---|---|---|---|")
        for status, old, new, added, deleted, action in entries:
            shown = old if old == new else f"{old} → {new}"
            lines.append(f"| {status} | `{shown}` | +{added}/-{deleted} | {action} |")
        lines.append("")
    if with_conflicts:
        found = conflicts(repo, base_rev, head, target)
        classify = conflict_classifier(repo, manifest, base_rev, target, head)
        lines.append(f"## Dry-run merge conflicts ({len(found)})\n")
        by_class = {}
        for kind, path in found:
            by_class.setdefault(classify(path), []).append((kind, path))
        lines.append("| class | conflicts | kinds |")
        lines.append("|---|---|---|")
        for cls, items in sorted(by_class.items()):
            kinds = {}
            for kind, _ in items:
                kinds[kind] = kinds.get(kind, 0) + 1
            lines.append(f"| {cls} | {len(items)} | " + ", ".join(f"{k} {n}" for k, n in sorted(kinds.items())) + " |")
        lines.append("")
        for cls, items in sorted(by_class.items()):
            if cls == "deleted":
                continue
            lines.append(f"- **{cls}**: " + ", ".join(f"`{p}`" + ("" if k == "content" else f" ({k})") for k, p in items))
        lines.append("")
    lines.append("## Upstream commits\n")
    lines += [f"- `{c.split(chr(9))[0]}` {c.split(chr(9))[1]} {c.split(chr(9), 2)[2]}" for c in commits]
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------- merge helpers

def merging(repo):
    return git_ok(repo, "rev-parse", "-q", "--verify", "MERGE_HEAD")


def unmerged_paths(repo):
    return [p for p in git(repo, "diff", "--name-only", "--diff-filter=U", "-z", strip=False).split("\0") if p]


def resolve_deleted(repo, dry_run=False):
    """During a merge, keep WinMux deletions. Returns (removed, needs_port)."""
    if not merging(repo):
        raise UsageError("no merge in progress")
    state = load_state(repo)
    manifest = Manifest.load(repo, "HEAD")
    renamed_from = {}
    for line in git(repo, "diff", "--name-status", "-M50%", state["upstream_base"], "MERGE_HEAD").splitlines():
        fields = line.split("\t")
        if fields[0].startswith("R"):
            renamed_from[fields[2]] = fields[1]
    removed, needs_port = [], []
    for path in unmerged_paths(repo):
        origin = renamed_from.get(path, path)
        if manifest.cls(origin) != "deleted":
            continue
        moved = manifest.moved_to(origin)
        if moved:
            needs_port.append((path, moved))
            continue
        removed.append(path)
    added = [p for p in git(repo, "diff", "--cached", "--name-only", "--diff-filter=A", "-z", "HEAD",
                            strip=False).split("\0") if p]
    for path in added:
        row = manifest.row(path)
        if row and row["cls"] == "deleted" and path not in removed:
            removed.append(path)
    if not dry_run:
        for start in range(0, len(removed), 100):
            git(repo, "rm", "-q", "-f", "--ignore-unmatch", "--", *removed[start:start + 100])
    return removed, needs_port


def current_branch(repo):
    return git(repo, "rev-parse", "--abbrev-ref", "HEAD")


def require_clean(repo):
    if git(repo, "status", "--porcelain", "--untracked-files=no"):
        raise UsageError("working tree has uncommitted changes")


def guard_main(repo, allow_main):
    if current_branch(repo) == "main" and not allow_main:
        raise UsageError("refusing to change main without --allow-main")


# ---------------------------------------------------------------- history join

def history_join_commands(state, upstream):
    fork, winmux = state["fork_point"], state["winmux_fork_commit"]
    return [
        "git switch main && git pull --ff-only origin main",
        f"git fetch --no-tags {state['upstream_url']} +refs/heads/main:{upstream}",
        f"test \"$(git rev-parse {fork}^{{tree}})\" = \"$(git rev-parse {winmux}^{{tree}})\"",
        f"git merge-base --is-ancestor {winmux} HEAD",
        f"git merge -s ours --no-ff -m \"{join_message(state).splitlines()[0]}\" {fork}",
        "test -z \"$(git diff --name-only HEAD^1 HEAD)\"",
        f"test \"$(git merge-base HEAD {upstream})\" = \"{fork}\"",
        "git push origin HEAD:main",
    ]


def join_message(state, trailers=()):
    fork, winmux = state["fork_point"], state["winmux_fork_commit"]
    body = (f"Join upstream AeroSpace history at fork point {fork[:8]}\n\n"
            f"WinMux {winmux[:8]} carries the same tree as upstream {fork[:8]} under rewritten\n"
            f"commit ids, so git computed an unrelated 2023 merge base. This merge records the\n"
            f"real ancestry and changes no files (strategy ours).\n")
    if trailers:
        body += "\n" + "\n".join(trailers) + "\n"
    return body


def history_join(repo, execute=False, allow_main=False, trailers=(), upstream=None):
    state = load_state(repo)
    fork, winmux = state["fork_point"], state["winmux_fork_commit"]
    upstream = upstream_ref(state, upstream)
    require_commit(repo, fork, "upstream fork point")
    require_commit(repo, winmux, "WinMux fork commit")
    if git(repo, "rev-parse", f"{fork}^{{tree}}") != git(repo, "rev-parse", f"{winmux}^{{tree}}"):
        raise UsageError("fork point and WinMux fork commit trees differ")
    if git_ok(repo, "merge-base", "--is-ancestor", fork, "HEAD"):
        return "already joined"
    if not git_ok(repo, "merge-base", "--is-ancestor", winmux, "HEAD"):
        raise UsageError(f"HEAD does not descend from {winmux[:8]}")
    if not execute:
        return "\n".join(history_join_commands(state, upstream))
    guard_main(repo, allow_main)
    require_clean(repo)
    before = git(repo, "rev-parse", "HEAD^{tree}")
    git(repo, "merge", "-s", "ours", "--no-ff", "--no-edit", "-m", join_message(state, trailers), fork)
    if git(repo, "rev-parse", "HEAD^{tree}") != before:
        raise UsageError("history join changed the tree; inspect HEAD before pushing")
    base = git(repo, "merge-base", "HEAD", upstream) if has_commit(repo, upstream) else fork
    if base != fork and not git_ok(repo, "merge-base", "--is-ancestor", fork, base):
        raise UsageError(f"merge base after join is {base}, expected {fork} or a descendant")
    return f"joined: {git(repo, 'rev-parse', '--short=12', 'HEAD')} (tree unchanged, merge base {base[:12]})"


# ---------------------------------------------------------------- CLI

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("-C", dest="repo", default=".", help="repository (default: current directory)")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("fetch", help="fetch upstream main and the recorded base without touching git config")
    p = sub.add_parser("guard", help="check every upstream path against its class")
    p.add_argument("--rev", default="HEAD")
    p.add_argument("--advisory", action="store_true", help="report but exit 0")
    p.add_argument("--limit", type=int, default=None, help="show at most N errors and N warnings")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("report", help="classify upstream changes since the last sync")
    p.add_argument("--upstream")
    p.add_argument("--head", default="HEAD")
    p.add_argument("--no-conflicts", action="store_true")
    p.add_argument("--out")
    p = sub.add_parser("merge", help="merge upstream (or a slice commit) with rerere and deletion auto-resolve")
    p.add_argument("target", nargs="?")
    p.add_argument("--allow-main", action="store_true")
    p = sub.add_parser("resolve-deleted", help="during a merge, keep files WinMux deleted")
    p.add_argument("--dry-run", action="store_true")
    p = sub.add_parser("finish", help="after resolving a merge: record the new base, refresh the manifest, commit")
    p.add_argument("--no-commit", action="store_true")
    p = sub.add_parser("manifest", help="add rows for unclassified upstream paths and refresh classes")
    p.add_argument("--base")
    p = sub.add_parser("history-join", help="record the real fork point (prints commands unless --execute)")
    p.add_argument("--execute", action="store_true")
    p.add_argument("--allow-main", action="store_true")
    p.add_argument("--trailer", action="append", default=[])
    p.add_argument("--upstream")
    args = parser.parse_args(argv)
    try:
        repo = repo_root(args.repo)
        state = load_state(repo)
        if args.command == "fetch":
            upstream = upstream_ref(state)
            git(repo, "fetch", "--no-tags", state["upstream_url"], f"+refs/heads/main:{upstream}")
            for rev in (state["upstream_base"], state["fork_point"]):
                if not has_commit(repo, rev):
                    git(repo, "fetch", "--no-tags", state["upstream_url"], rev)
            print(f"{upstream} = {git(repo, 'rev-parse', '--short=12', upstream)}")
        elif args.command == "guard":
            errors, warnings, summary = guard(repo, args.rev)
            if args.json:
                print(json.dumps({"errors": errors, "warnings": warnings, "summary": {
                    **summary, "pending_transitions": {f"{a}->{b}": n for (a, b), n in
                                                       summary["pending_transitions"].items()}}}, indent=2))
            else:
                print_guard(errors, warnings, summary, limit=args.limit)
            if errors and not args.advisory:
                return 1
        elif args.command == "report":
            text = report(repo, upstream_ref(state, args.upstream), args.head, not args.no_conflicts)
            if args.out:
                Path(args.out).write_text(text)
                print(args.out)
            else:
                sys.stdout.write(text)
        elif args.command == "merge":
            target = args.target or upstream_ref(state)
            guard_main(repo, args.allow_main)
            require_clean(repo)
            require_commit(repo, target, "merge target")
            out_dir = repo / ".local" / "upstream-sync"
            out_dir.mkdir(parents=True, exist_ok=True)
            report_path = out_dir / f"report-{git(repo, 'rev-parse', '--short=12', target)}.md"
            report_path.write_text(report(repo, target))
            print(f"report: {report_path}")
            result = subprocess.run(["git", "-C", str(repo), *RERERE, "merge", "--no-ff", "--no-commit", target])
            if not merging(repo):
                return result.returncode
            removed, needs_port = resolve_deleted(repo)
            print(f"auto-resolved {len(removed)} deleted path(s)")
            for path, moved in needs_port:
                print(f"PORT {path} -> {moved}")
            left = unmerged_paths(repo)
            classify = conflict_classifier(repo, Manifest.load(repo, "HEAD"), state["upstream_base"], target)
            labels = {}
            for path in left:
                labels.setdefault(classify(path), []).append(path)
            for label, paths in sorted(labels.items()):
                for path in paths:
                    print(f"CONFLICT [{label}] {path}")
            print("remaining: " + ", ".join(f"{label} {len(paths)}" for label, paths in sorted(labels.items())))
            print("resolve the rest, then run: script/upstream-sync.py finish")
            return 1 if left else 0
        elif args.command == "resolve-deleted":
            removed, needs_port = resolve_deleted(repo, args.dry_run)
            for path in removed:
                print(f"{'would remove' if args.dry_run else 'removed'} {path}")
            for path, moved in needs_port:
                print(f"PORT {path} -> {moved}")
        elif args.command == "finish":
            if not merging(repo):
                raise UsageError("no merge in progress")
            if unmerged_paths(repo):
                raise UsageError("unresolved paths remain")
            target = git(repo, "rev-parse", "MERGE_HEAD")
            state["upstream_base"] = target
            save_state(repo, state)
            manifest, added, dropped, changed = update_manifest(repo, Manifest.load(repo), target,
                                                                git(repo, "write-tree"))
            manifest.save(repo)
            git(repo, "add", STATE_PATH, MANIFEST_PATH)
            print(f"manifest: +{len(added)} rows, -{len(dropped)} rows, {len(changed)} reclassified")
            if not args.no_commit:
                subprocess.run(["git", "-C", str(repo), *RERERE, "commit", "--no-edit"], check=True)
        elif args.command == "manifest":
            base_rev = args.base or state["upstream_base"]
            path = repo / MANIFEST_PATH
            current = Manifest.load(repo) if path.exists() else Manifest([])
            manifest, added, dropped, changed = update_manifest(repo, current, base_rev)
            manifest.save(repo)
            print(f"manifest: +{len(added)} rows, -{len(dropped)} rows, {len(changed)} reclassified")
            for item in changed:
                print("reclassified %s: %s -> %s" % item)
        elif args.command == "history-join":
            print(history_join(repo, args.execute, args.allow_main, args.trailer, args.upstream))
    except UsageError as error:
        print(f"upstream-sync: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
