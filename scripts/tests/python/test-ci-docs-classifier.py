#!/usr/bin/env python3
"""Real Git history and workflow bootstrap fixtures for documentation CI routing."""

import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

from tooling_test_paths import REPOSITORY_ROOT


CLASSIFIER = REPOSITORY_ROOT / "scripts" / "classify-ci-docs.py"
WORKFLOW = REPOSITORY_ROOT / ".github" / "workflows" / "ci.yaml"
SPEC = importlib.util.spec_from_file_location("ci_docs_classifier", CLASSIFIER)
assert SPEC is not None and SPEC.loader is not None
CLASSIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLASSIFY)


def workflow_run_block(step_name: str) -> str:
    source = WORKFLOW.read_text(encoding="utf-8")
    match = re.search(
        rf"(?m)^      - name: {re.escape(step_name)}\n"
        r"(?:(?!^      - name:|^  [a-z]+:).)*?^        run: \|\n"
        r"(?P<body>(?:^          [^\n]*\n|^\n)+)",
        source,
        re.DOTALL,
    )
    if match is None:
        raise AssertionError(f"Missing workflow run block: {step_name}")
    return "\n".join(line[10:] for line in match.group("body").splitlines()) + "\n"


def git(root: Path, *args: str) -> str:
    return subprocess.check_output(
        ("git", *args), cwd=root, stderr=subprocess.DEVNULL, text=True
    ).strip()


class RawDiffTests(unittest.TestCase):
    def test_exact_ordinary_modification_only(self) -> None:
        header = b":" + b"100644 100644 " + b"0" * 40 + b" " + b"1" * 40 + b" M\0"
        self.assertTrue(CLASSIFY.allowed_raw_diff(header + b"docs/USER-GUIDE.md\0"))
        for path in (
            b"README.md", b"DEVELOPMENT.md", b"DISTRIBUTION.md",
            b"SAFETY.md", b"config/tracked-documents.txt",
            b"docs/other.md", b"docs/space name.md",
            "docs/유니코드.md".encode(), b"docs/new\nline.md", b"-option.md",
        ):
            with self.subTest(path=path):
                self.assertFalse(CLASSIFY.allowed_raw_diff(header + path + b"\0"))
        for raw in (
            b"", header, header + b"docs/USER-GUIDE.md",
            header + b"docs/USER-GUIDE.md\0extra\0",
            header + b"docs/USER-GUIDE.md\0" * 2,
            header.replace(b"100644", b"100755", 1) + b"docs/USER-GUIDE.md\0",
            header.replace(b" M\0", b" A\0") + b"docs/USER-GUIDE.md\0",
            header.replace(b" M\0", b" R100\0") + b"docs/USER-GUIDE.md\0",
            header.replace(b"0" * 40, b"z" * 40, 1) + b"docs/USER-GUIDE.md\0",
        ):
            with self.subTest(raw=raw):
                self.assertFalse(CLASSIFY.allowed_raw_diff(raw))


class GitHistoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="darkrenamer-ci-docs-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "checkout"
        self.root.mkdir()
        git(self.root, "init", "-b", "master")
        git(self.root, "config", "user.email", "fixture@example.invalid")
        git(self.root, "config", "user.name", "CI fixture")
        (self.root / "scripts").mkdir()
        (self.root / "docs").mkdir()
        (self.root / "scripts" / CLASSIFIER.name).write_bytes(CLASSIFIER.read_bytes())
        (self.root / "docs" / "USER-GUIDE.md").write_text("initial\n")
        (self.root / "README.md").write_text("initial\n")
        self.base = self.commit()
        self.origin = Path(self.temporary.name) / "origin.git"
        subprocess.run(("git", "init", "--bare", str(self.origin)), check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        git(self.root, "remote", "add", "origin", str(self.origin))
        git(self.root, "push", "origin", "master")

    def commit(self) -> str:
        git(self.root, "add", "-A")
        git(self.root, "commit", "-m", "fixture")
        return git(self.root, "rev-parse", "HEAD")

    def edit(self, path: str, content: str) -> str:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        return self.commit()

    def decide(self, event: str, head: str, before: str = "") -> str:
        output = Path(self.temporary.name) / "output"
        output.write_text("")
        env = dict(os.environ, EVENT_NAME=event, EVENT_SHA=head,
                   EVENT_BEFORE=before, RUNNER_TEMP=self.temporary.name,
                   GITHUB_OUTPUT=str(output))
        subprocess.run(("bash", "-e"), input=workflow_run_block("Classify with protected policy"),
                       text=True, cwd=self.root, env=env, check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return output.read_text().strip()

    def test_allowed_document_and_mixed_multicommit(self) -> None:
        head = self.edit("docs/USER-GUIDE.md", "first\n")
        self.assertEqual(self.decide("pull_request", head), "docs_only=true")
        self.assertEqual(self.decide("push", head, self.base), "docs_only=true")
        head = self.edit("docs/USER-GUIDE.md", "second\n")
        self.assertEqual(self.decide("merge_group", head), "docs_only=true")
        for path in ("README.md", "DEVELOPMENT.md", "DISTRIBUTION.md",
                     ".github/workflows/ci.yaml", "src/main.rs", "docs/unknown.md"):
            with self.subTest(path=path):
                head = self.edit(path, "changed\n")
                self.assertEqual(self.decide("pull_request", head), "docs_only=false")

    def test_tree_operations_and_unusual_paths_select_full(self) -> None:
        path = self.root / "docs" / "USER-GUIDE.md"
        path.unlink()
        self.assertEqual(self.decide("pull_request", self.commit()), "docs_only=false")
        for name in ("README.ko.md", "docs/space name.md", "docs/new\nline.md",
                     "docs/名前.md", "-flag.md"):
            head = self.edit(name, "new\n")
            self.assertEqual(self.decide("pull_request", head), "docs_only=false")

    def test_mode_rename_symlink_and_gitlink_select_full(self) -> None:
        path = self.root / "docs" / "USER-GUIDE.md"
        path.chmod(0o755)
        self.assertEqual(self.decide("pull_request", self.commit()), "docs_only=false")
        git(self.root, "mv", "docs/USER-GUIDE.md", "docs/USER-GUIDE.ko.md")
        self.assertEqual(self.decide("pull_request", self.commit()), "docs_only=false")
        path = self.root / "README.md"
        path.unlink()
        path.symlink_to("docs/USER-GUIDE.ko.md")
        self.assertEqual(self.decide("pull_request", self.commit()), "docs_only=false")
        git(self.root, "update-index", "--add", "--cacheinfo", "160000", self.base,
            "external-module")
        git(self.root, "commit", "-m", "fixture gitlink")
        self.assertEqual(
            self.decide("pull_request", git(self.root, "rev-parse", "HEAD")),
            "docs_only=false",
        )

    def test_untrusted_policy_in_earlier_queue_entry_cannot_select_docs(self) -> None:
        head = self.edit("scripts/classify-ci-docs.py", "print('true')\n")
        head = self.edit("docs/USER-GUIDE.md", "later queue entry\n")
        self.assertEqual(self.decide("merge_group", head), "docs_only=false")

    def test_missing_nonancestor_manual_unknown_and_wrong_head(self) -> None:
        head = self.edit("docs/USER-GUIDE.md", "changed\n")
        self.assertEqual(self.decide("workflow_dispatch", head), "docs_only=false")
        self.assertEqual(self.decide("unexpected", head), "docs_only=false")
        self.assertEqual(self.decide("push", head, "0" * 40), "docs_only=false")
        self.assertEqual(self.decide("pull_request", self.base), "docs_only=false")
        git(self.root, "checkout", "--orphan", "unrelated")
        (self.root / "docs" / "USER-GUIDE.md").write_text("orphan\n")
        orphan = self.commit()
        self.assertEqual(self.decide("merge_group", orphan), "docs_only=false")

    def test_missing_trusted_helper_selects_full(self) -> None:
        git(self.root, "checkout", "--orphan", "pre-rollout")
        git(self.root, "rm", "-rf", ".")
        (self.root / "docs").mkdir(exist_ok=True)
        (self.root / "docs" / "USER-GUIDE.md").write_text("before\n")
        prior = self.commit()
        git(self.root, "checkout", "-b", "trial")
        head = self.edit("docs/USER-GUIDE.md", "after\n")
        self.assertEqual(self.decide("push", head, prior), "docs_only=false")

    def test_malformed_trusted_results_never_select_docs(self) -> None:
        for source in ("print('TRUE')\n", "print('true')\n",
                       "print('true extra')\n", "pass\n",
                       "raise RuntimeError('failed')\n"):
            with self.subTest(source=source):
                base = self.edit("scripts/classify-ci-docs.py", source)
                git(self.root, "push", "origin", "master")
                head = self.edit("docs/USER-GUIDE.md", f"head {base}\n")
                self.assertEqual(self.decide("pull_request", head), "docs_only=false")

    def test_selected_document_inventory_failure_blocks_quality(self) -> None:
        head = self.edit("docs/USER-GUIDE.md", "changed\n")
        self.assertEqual(self.decide("pull_request", head), "docs_only=true")
        (self.root / "config").mkdir()
        (self.root / "config" / "tracked-documents.txt").write_text("README.md\n")
        result = subprocess.run(
            ("bash", "-e"), input=workflow_run_block("Enforce the Rust-only source tree"),
            text=True, cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Tracked documentation differs", result.stderr)


if __name__ == "__main__":
    unittest.main()
