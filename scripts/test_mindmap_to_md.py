#!/usr/bin/env python3
"""Tests for scripts/mindmap_to_md.py.

The converter derives its input and output paths from its own location, so the
tests run it from a temp directory that holds a copy of the script. That keeps
the CLI contract exactly as specified - no extra flags to test around.

Run: python3 scripts/test_mindmap_to_md.py
"""
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from xml.sax.saxutils import escape

REPO = Path(__file__).resolve().parent.parent
CONVERTER = REPO / "scripts" / "mindmap_to_md.py"
SOURCE_NAME = "Поливалка Arduino.mm"
OUT_REL = Path("docs") / "legacy" / "Поливалка_Arduino.md"


def make_mm(node):
    """Build a minimal FreeMind XML file from a nested tree.

    Nesting comes from element nesting, not from whitespace: FreeMind ignores
    indentation. A branch is (text, children); a leaf is just its text.
    """
    lines = ['<map version="1.1.0">']

    def emit(current, depth):
        text, children = (current, ()) if isinstance(current, str) else current
        pad = " " * (4 * depth)
        lines.append('%s<node TEXT="%s">' % (pad, escape(text)))
        for child in children:
            emit(child, depth + 1)
        lines.append("%s</node>" % pad)

    emit(node, 1)
    lines.append("</map>")
    return "\n".join(lines) + "\n"


# "Корень" > ("Ветка 1" > ("Лист 1", "Лист 2"), "Ветка 2")
FIXTURE_TREE = ("Корень", (("Ветка 1", ("Лист 1", "Лист 2")), "Ветка 2"))
FIXTURE = make_mm(FIXTURE_TREE)
FIXTURE_NODES = 5


class ConverterCase(unittest.TestCase):
    """Runs the converter out of a throwaway copy of the repo layout."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, True)
        (self.dir / "scripts").mkdir()
        shutil.copy(CONVERTER, self.dir / "scripts" / CONVERTER.name)
        (self.dir / SOURCE_NAME).write_text(FIXTURE, encoding="utf-8")
        self.out = self.dir / OUT_REL

    def run_converter(self, *args):
        return subprocess.run(
            [sys.executable, "scripts/mindmap_to_md.py", *args],
            cwd=self.dir,
            capture_output=True,
            text=True,
        )

    def write_artifact(self, text="снимок\n"):
        self.out.parent.mkdir(parents=True, exist_ok=True)
        self.out.write_text(text, encoding="utf-8")


class TestGenerate(ConverterCase):
    def test_writes_the_artifact(self):
        result = self.run_converter()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.out.exists(), "artifact was not created")

    def test_unescapes_cyrillic_entities(self):
        self.run_converter()
        text = self.out.read_text(encoding="utf-8")
        for expected in ("Корень", "Ветка 1", "Лист 1", "Лист 2", "Ветка 2"):
            self.assertIn(expected, text)
        self.assertNotIn("&#x", text)

    def test_nesting_becomes_indentation(self):
        self.run_converter()
        lines = self.out.read_text(encoding="utf-8").splitlines()
        indent = {}
        for line in lines:
            body = line.strip()
            for marker in ("- ", "## ", "# "):
                if body.startswith(marker):
                    indent[body[len(marker):]] = len(line) - len(line.lstrip())
                    break
        self.assertGreater(indent["Ветка 1"], indent["Корень"])
        self.assertGreater(indent["Лист 1"], indent["Ветка 1"])
        self.assertEqual(indent["Ветка 1"], indent["Ветка 2"])

    def test_exactly_one_h1(self):
        """The snapshot header is the only document title; the tree root is demoted."""
        self.run_converter()
        h1 = [l for l in self.out.read_text(encoding="utf-8").splitlines()
              if l.startswith("# ")]
        self.assertEqual(len(h1), 1, "expected one H1, got %r" % h1)

    def test_top_node_is_demoted_to_h2(self):
        self.run_converter()
        text = self.out.read_text(encoding="utf-8")
        self.assertIn("## Корень", text)
        self.assertNotIn("\n# Корень", text)

    def test_reports_node_count(self):
        result = self.run_converter()
        self.assertIn("%d nodes" % FIXTURE_NODES, result.stdout)

    def test_generation_is_idempotent(self):
        self.run_converter()
        first = self.out.read_bytes()
        self.run_converter()
        self.assertEqual(self.out.read_bytes(), first)

    def test_header_marks_the_file_as_generated(self):
        self.run_converter()
        text = self.out.read_text(encoding="utf-8")
        self.assertIn("mindmap_to_md.py", text)
        self.assertIn("Не редактировать руками", text)


class TestCheck(ConverterCase):
    def test_check_passes_on_a_fresh_artifact(self):
        self.run_converter()
        result = self.run_converter("--check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("up to date", result.stdout)

    def test_check_fails_when_artifact_is_missing(self):
        result = self.run_converter("--check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("MISSING", result.stdout)

    def test_check_fails_on_drift(self):
        self.run_converter()
        self.out.write_text(self.out.read_text(encoding="utf-8") + "ручная правка\n",
                            encoding="utf-8")
        result = self.run_converter("--check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("DRIFT", result.stdout)

    def test_check_does_not_write_the_artifact(self):
        self.run_converter("--check")
        self.assertFalse(self.out.exists(), "--check must not create the artifact")

    def test_check_discriminates(self):
        """The gate has to be able to fail, or it is decoration."""
        codes = set()
        for mutate in ("missing", "drift"):
            case = ConverterCase("run")
            case.setUp()
            try:
                if mutate == "missing":
                    pass
                else:
                    case.run_converter()
                    case.out.write_text("x\n", encoding="utf-8")
                codes.add(case.run_converter("--check").returncode)
            finally:
                shutil.rmtree(case.dir, True)
        self.assertEqual(codes, {1})
        fresh = ConverterCase("run")
        fresh.setUp()
        try:
            fresh.run_converter()
            self.assertEqual(fresh.run_converter("--check").returncode, 0)
        finally:
            shutil.rmtree(fresh.dir, True)


class TestRealMap(ConverterCase):
    """The real 470-node map, run through a copy so the repo is untouched."""

    def setUp(self):
        super().setUp()
        (self.dir / SOURCE_NAME).write_text(
            (REPO / SOURCE_NAME).read_text(encoding="utf-8"), encoding="utf-8")

    def test_node_count_matches_the_recon_figure(self):
        result = self.run_converter()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("470 nodes", result.stdout)

    def test_goals_branch_survives_conversion(self):
        self.run_converter()
        text = self.out.read_text(encoding="utf-8")
        self.assertIn("Цели", text)
        self.assertIn("забыть", text)

    def test_deepest_branch_is_not_flattened(self):
        self.run_converter()
        lines = self.out.read_text(encoding="utf-8").splitlines()
        indents = [len(l) - len(l.lstrip()) for l in lines
                   if l.lstrip().startswith("- ")]
        self.assertGreater(max(indents), 0, "tree was flattened")
        self.assertGreater(len(set(indents)), 3, "tree is too shallow to be the real map")


if __name__ == "__main__":
    unittest.main(verbosity=2)