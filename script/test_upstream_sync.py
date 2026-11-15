"""Exercise the upstream-sync tooling on small synthetic fork histories."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("upstream_sync", Path(__file__).with_name("upstream-sync.py"))
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)

GIT_ENV = {
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "Test",
    "GIT_AUTHOR_EMAIL": "test@example.invalid",
    "GIT_COMMITTER_NAME": "Test",
    "GIT_COMMITTER_EMAIL": "test@example.invalid",
    "GIT_TERMINAL_PROMPT": "0",
}

UPSTREAM_FILES = {
    "Sources/core.swift": "let a = 1\nlet b = 2\nlet c = 3\n",
    "Sources/hooked.swift": "func f() {\n    one()\n    two()\n}\n\nfunc g() {\n    three()\n}\n",
    "Sources/forked.swift": "let mode = \"upstream\"\n",
    "Sources/moved.swift": "struct Moved {}\n",
    "docs/guide.adoc": "= Guide\n",
    "old.sh": "echo old\n",
}


class Repo:
    def __init__(self, path):
        self.path = Path(path)

    def git(self, *args, check=True):
        result = subprocess.run(["git", "-C", str(self.path), *args], capture_output=True, text=True)
        if check and result.returncode != 0:
            raise AssertionError(f"git {args} failed: {result.stderr}")
        return result.stdout.strip()

    def write(self, rel, text):
        target = self.path / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def remove(self, rel):
        self.git("rm", "-q", rel)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")


def manifest_text(extra=""):
    return sync.MANIFEST_HEADER + (
        "pristine\tSources/core.swift\n"
        "hooked\tSources/hooked.swift\n"
        "forked\tSources/forked.swift\n"
        "deleted\tSources/moved.swift\t\tmoved-to=Sources/ui/moved.swift\n"
        "deleted\told.sh\n"
        "deleted\tdocs/*.adoc\t\tupstream docs site\n"
    ) + extra


class ForkFixture(unittest.TestCase):
    """upstream U0 -> U1; WinMux W0 (same tree as U0, rewritten id) -> W1."""

    def setUp(self):
        patcher = mock.patch.dict(os.environ, GIT_ENV)
        patcher.start()
        self.addCleanup(patcher.stop)
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.repo = Repo(directory.name)
        self.repo.git("init", "-q", "-b", "upstream-main")
        self.repo.write("Sources/core.swift", "let a = 1\n")
        self.ancient = self.repo.commit("ancient shared history")
        for rel, text in UPSTREAM_FILES.items():
            self.repo.write(rel, text)
        self.u0 = self.repo.commit("upstream base")
        self.repo.git("checkout", "-q", "-b", "work", self.ancient)
        for rel, text in UPSTREAM_FILES.items():
            self.repo.write(rel, text)
        self.w0 = self.repo.commit("upstream base (rewritten)")
        self.assertEqual(self.repo.git("rev-parse", f"{self.u0}^{{tree}}"), self.repo.git("rev-parse", "HEAD^{tree}"))
        self.repo.write("Sources/hooked.swift", UPSTREAM_FILES["Sources/hooked.swift"].replace(
            "    one()\n", "    one()\n    WinMux.hooks.afterOne() // WINMUX-HOOK(afterOne)\n"))
        self.repo.write("Sources/forked.swift", "let mode = \"winmux\"\n")
        self.repo.remove("docs/guide.adoc")
        self.repo.remove("old.sh")
        self.repo.remove("Sources/moved.swift")
        self.repo.write("Sources/ui/moved.swift", "struct Moved { let winmux = true }\n")
        self.repo.write("Sources/winmux.swift", "struct WinMuxOnly {}\n")
        self.repo.write("docs/winmux.md", "# WinMux\n")
        self.repo.write(sync.STATE_PATH, json.dumps({
            "upstream_url": "https://example.invalid/upstream.git",
            "upstream_ref": "upstream-main",
            "fork_point": self.u0,
            "winmux_fork_commit": self.w0,
            "upstream_base": self.u0,
            "forked_budget": 10,
        }))
        self.repo.write(sync.MANIFEST_PATH, manifest_text())
        self.w1 = self.repo.commit("winmux changes")
        self.repo.git("checkout", "-q", "upstream-main")
        self.repo.write("Sources/core.swift", UPSTREAM_FILES["Sources/core.swift"] + "let d = 4\n")
        self.repo.write("Sources/hooked.swift", UPSTREAM_FILES["Sources/hooked.swift"].replace("three()", "three(4)"))
        self.repo.write("Sources/forked.swift", "let mode = \"upstream-2\"\n")
        self.repo.write("Sources/moved.swift", "struct Moved { let upstream = 2 }\n")
        self.repo.write("docs/guide.adoc", "= Guide v2\n")
        self.repo.write("docs/new.adoc", "= New\n")
        self.repo.write("Sources/new.swift", "struct New {}\n")
        self.u1 = self.repo.commit("upstream changes")
        self.repo.git("checkout", "-q", "work")

    def guard_messages(self, rev="HEAD"):
        errors, warnings, summary = sync.guard(self.repo.path, rev)
        return [f"{p}: {m}" for p, m in errors], [f"{p}: {m}" for p, m in warnings], summary

    def amend(self, rel, text):
        self.repo.write(rel, text)
        return self.repo.commit(f"edit {rel}")


class GuardTest(ForkFixture):
    def test_consistent_fork_passes(self):
        errors, warnings, summary = self.guard_messages()
        self.assertEqual(errors, [])
        self.assertEqual(summary["counts"]["pristine"], 1)
        self.assertEqual(summary["counts"]["hooked"], 1)
        self.assertEqual(summary["winmux_only_files"], 5)

    def test_modified_pristine_file_is_an_error(self):
        self.amend("Sources/core.swift", "let a = 10\nlet b = 2\nlet c = 3\n")
        errors, _, _ = self.guard_messages()
        self.assertEqual(errors, ["Sources/core.swift: pristine file differs from upstream"])

    def test_hooked_file_rejects_unmarked_and_removed_lines(self):
        text = (self.repo.path / "Sources/hooked.swift").read_text()
        self.amend("Sources/hooked.swift", text.replace("    two()\n", "    twoPrime()\n    extra()\n"))
        errors, _, _ = self.guard_messages()
        self.assertTrue(any("removes or edits upstream line: two()" in e for e in errors), errors)
        self.assertTrue(any("unmarked added line: extra()" in e for e in errors), errors)

    def test_hooked_file_accepts_marked_blocks(self):
        text = (self.repo.path / "Sources/hooked.swift").read_text()
        block = ("    // WINMUX-HOOK-BEGIN(g)\n    if WinMux.hooks.skipG() {\n        return\n    }\n"
                 "    // WINMUX-HOOK-END(g)\n")
        self.amend("Sources/hooked.swift", text.replace("func g() {\n", "func g() {\n" + block))
        errors, _, _ = self.guard_messages()
        self.assertEqual(errors, [])

    def test_unterminated_hook_block_is_an_error(self):
        text = (self.repo.path / "Sources/hooked.swift").read_text()
        self.amend("Sources/hooked.swift", text.replace("func g() {\n", "func g() {\n    // WINMUX-HOOK-BEGIN(g)\n    x()\n"))
        errors, _, _ = self.guard_messages()
        self.assertTrue(any("WINMUX-HOOK-BEGIN without WINMUX-HOOK-END" in e for e in errors), errors)

    def test_deleted_path_and_deleted_glob_must_stay_absent(self):
        self.repo.write("old.sh", "echo back\n")
        self.repo.write("docs/extra.adoc", "= Extra\n")
        self.repo.commit("bring files back")
        errors, _, _ = self.guard_messages()
        self.assertIn("old.sh: deleted upstream path exists in WinMux", errors)
        self.assertIn("docs/extra.adoc: matches deleted pattern docs/*.adoc", errors)

    def test_unclassified_and_stale_rows_are_errors(self):
        self.repo.write(sync.MANIFEST_PATH, manifest_text("forked\tSources/winmux.swift\n").replace(
            "pristine\tSources/core.swift\n", ""))
        self.repo.commit("break manifest")
        errors, _, _ = self.guard_messages()
        self.assertIn("Sources/core.swift: upstream path is not classified in the manifest", errors)
        self.assertIn("Sources/winmux.swift: classified forked but not an upstream path", errors)

    def test_forked_identical_file_warns_and_budget_counts_sources(self):
        self.amend("Sources/forked.swift", UPSTREAM_FILES["Sources/forked.swift"])
        self.repo.write(sync.STATE_PATH, (self.repo.path / sync.STATE_PATH).read_text().replace(
            '"forked_budget": 10', '"forked_budget": 0'))
        self.repo.commit("tighten budget")
        errors, warnings, _ = self.guard_messages()
        self.assertEqual(errors, [])
        self.assertIn("Sources/forked.swift: forked file is identical to upstream (classify it pristine)", warnings)
        self.assertTrue(any("(budget)" in w for w in warnings), warnings)

    def test_cli_advisory_exits_zero_and_strict_exits_one(self):
        self.amend("Sources/core.swift", "changed\n")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(sync.main(["-C", str(self.repo.path), "guard", "--advisory"]), 0)
            self.assertEqual(sync.main(["-C", str(self.repo.path), "guard"]), 1)


class ManifestTest(unittest.TestCase):
    def test_globs_are_limited_to_deleted_and_winmux_only(self):
        with self.assertRaises(sync.UsageError):
            sync.Manifest.parse("pristine\tSources/*.swift\n")
        manifest = sync.Manifest.parse("deleted\tdocs/*.adoc\nwinmux-only\tSources/ui/*\n")
        self.assertEqual(manifest.cls("docs/a/b.adoc"), "deleted")
        self.assertEqual(manifest.cls("Sources/ui/x/y.swift"), "winmux-only")
        self.assertIsNone(manifest.cls("Sources/core.swift"))

    def test_unknown_class_and_duplicates_are_rejected(self):
        with self.assertRaises(sync.UsageError):
            sync.Manifest.parse("vendored\ta.swift\n")
        with self.assertRaises(sync.UsageError):
            sync.Manifest.parse("pristine\ta.swift\nforked\ta.swift\n")

    def test_render_round_trips(self):
        text = manifest_text()
        manifest = sync.Manifest.parse(text)
        def key(row):
            return row["path"]
        self.assertEqual(sorted(sync.Manifest.parse(manifest.render()).rows, key=key), sorted(manifest.rows, key=key))
        self.assertEqual(manifest.moved_to("Sources/moved.swift"), "Sources/ui/moved.swift")


class HistoryJoinTest(ForkFixture):
    def test_prints_commands_without_changing_anything(self):
        before = self.repo.git("rev-parse", "HEAD")
        text = sync.history_join(self.repo.path)
        self.assertIn(f"git merge -s ours --no-ff", text)
        self.assertIn(self.u0, text)
        self.assertEqual(self.repo.git("rev-parse", "HEAD"), before)

    def test_join_records_fork_point_without_changing_tree(self):
        self.assertEqual(self.repo.git("merge-base", "HEAD", self.u1), self.ancient)
        tree = self.repo.git("rev-parse", "HEAD^{tree}")
        result = sync.history_join(self.repo.path, execute=True, trailers=["Co-Authored-By: Test <t@example.invalid>"])
        self.assertIn("tree unchanged", result)
        self.assertEqual(self.repo.git("rev-parse", "HEAD^{tree}"), tree)
        self.assertEqual(self.repo.git("merge-base", "HEAD", self.u1), self.u0)
        self.assertIn("Co-Authored-By: Test", self.repo.git("log", "-1", "--format=%B"))
        self.assertEqual(sync.history_join(self.repo.path), "already joined")

    def test_refuses_main_without_flag_and_dirty_trees(self):
        self.repo.git("branch", "-m", "work", "main")
        with self.assertRaises(sync.UsageError):
            sync.history_join(self.repo.path, execute=True)
        self.repo.write("Sources/winmux.swift", "dirty\n")
        with self.assertRaises(sync.UsageError):
            sync.history_join(self.repo.path, execute=True, allow_main=True)

    def test_rejects_mismatched_trees(self):
        state = json.loads((self.repo.path / sync.STATE_PATH).read_text())
        state["winmux_fork_commit"] = self.w1
        self.repo.write(sync.STATE_PATH, json.dumps(state))
        with self.assertRaises(sync.UsageError):
            sync.history_join(self.repo.path)


class ReportAndMergeTest(ForkFixture):
    def setUp(self):
        super().setUp()
        sync.history_join(self.repo.path, execute=True)

    def test_report_classifies_upstream_changes(self):
        text = sync.report(self.repo.path, "upstream-main")
        self.assertIn("upstream commits since base: 1", text)
        self.assertIn("| M | `Sources/forked.swift` | +1/-1 | PORT BY HAND: review the upstream diff |", text)
        self.assertIn("| M | `Sources/core.swift` | +1/-0 | merges as is |", text)
        self.assertIn("| M | `Sources/hooked.swift` | +1/-1 | merges; re-check WINMUX-HOOK lines |", text)
        self.assertIn("PORT BY HAND to `Sources/ui/moved.swift`", text)
        self.assertIn("| A | `docs/new.adoc` | +1/-0 | auto-resolved: new file under a deleted pattern is dropped |", text)
        self.assertIn("| A | `Sources/new.swift` | +1/-0 | new upstream file: becomes pristine |", text)
        self.assertIn("- **forked**: `Sources/forked.swift`", text)
        self.assertIn("| deleted | 1 | modify/delete 1 |", text)
        self.assertIn("- **deleted, moved: port by hand**: `Sources/moved.swift` (modify/delete)", text)

    def test_merge_auto_resolves_deletions_and_finish_records_base(self):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            code = sync.main(["-C", str(self.repo.path), "merge", "upstream-main"])
        self.assertEqual(code, 1, out.getvalue())
        self.assertIn("CONFLICT [forked] Sources/forked.swift", out.getvalue())
        self.assertIn("PORT Sources/moved.swift -> Sources/ui/moved.swift", out.getvalue())
        self.assertFalse((self.repo.path / "docs/guide.adoc").exists())
        self.assertFalse((self.repo.path / "docs/new.adoc").exists())
        self.assertEqual((self.repo.path / "Sources/core.swift").read_text(), "let a = 1\nlet b = 2\nlet c = 3\nlet d = 4\n")
        self.assertIn("three(4)", (self.repo.path / "Sources/hooked.swift").read_text())
        self.assertIn("WINMUX-HOOK(afterOne)", (self.repo.path / "Sources/hooked.swift").read_text())
        self.repo.write("Sources/forked.swift", "let mode = \"winmux\"\n")
        self.repo.write("Sources/ui/moved.swift", "struct Moved { let winmux = true; let upstream = 2 }\n")
        self.repo.git("add", "Sources/forked.swift", "Sources/ui/moved.swift")
        self.repo.git("rm", "-q", "Sources/moved.swift")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(sync.main(["-C", str(self.repo.path), "finish"]), 0)
        self.assertEqual(self.repo.git("rev-parse", "HEAD^2"), self.u1)
        state = json.loads(self.repo.git("show", f"HEAD:{sync.STATE_PATH}"))
        self.assertEqual(state["upstream_base"], self.u1)
        manifest = sync.Manifest.load(self.repo.path, "HEAD")
        self.assertEqual(manifest.cls("Sources/new.swift"), "pristine")
        self.assertEqual(manifest.cls("Sources/core.swift"), "pristine")
        errors, _, _ = sync.guard(self.repo.path)
        self.assertEqual(errors, [])

    def test_resolve_deleted_requires_a_merge(self):
        with self.assertRaises(sync.UsageError):
            sync.resolve_deleted(self.repo.path)


if __name__ == "__main__":
    unittest.main()
