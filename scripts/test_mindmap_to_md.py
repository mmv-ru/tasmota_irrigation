#!/usr/bin/env python3
"""Tests for scripts/mindmap_to_md.py.

The converter derives its input and output paths from its own location, so the
tests run it from a temp directory that holds a copy of the script. That keeps
the CLI contract exactly as specified - no extra flags to test around.

Run: python3 scripts/test_mindmap_to_md.py
"""
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path
from xml.sax.saxutils import escape

REPO = Path(__file__).resolve().parent.parent
CONVERTER = REPO / "scripts" / "mindmap_to_md.py"
SOURCE_NAME = "Поливалка Arduino.mm"
OUT_REL = Path("docs") / "legacy" / "Поливалка_Arduino.md"


def make_mm(node):
    """Build a minimal FreeMind XML file from a nested tree.

    Nesting comes from element nesting, not from whitespace: FreeMind ignores
    indentation. A node is either a plain string (leaf) or a dict with keys
    "text", optional "icon", and optional "children".
    """
    lines = ['<map version="1.1.0">']

    def emit(current, depth):
        if isinstance(current, str):
            text, icon, children = current, (), ()
        else:
            text = current["text"]
            raw = current.get("icon", ())
            if isinstance(raw, str):
                icon = (raw,) if raw else ()
            else:
                icon = tuple(raw)
            children = current.get("children", ())
        pad = " " * (4 * depth)
        lines.append('%s<node TEXT="%s">' % (pad, escape(text)))
        for name in icon:
            lines.append('%s  <icon BUILTIN="%s"/>' % (pad, name))
        for child in children:
            emit(child, depth + 1)
        lines.append("%s</node>" % pad)

    emit(node, 1)
    lines.append("</map>")
    return "\n".join(lines) + "\n"


# "Корень" > ("Ветка 1" > ("Лист 1", "Лист 2"), "Ветка 2")
FIXTURE_TREE = {"text": "Корень", "children": [
    {"text": "Ветка 1", "children": ["Лист 1", "Лист 2"]},
    "Ветка 2",
]}
FIXTURE = make_mm(FIXTURE_TREE)
FIXTURE_NODES = 5

# Same tree, with one leaf carrying an icon.
ICON_FIXTURE = make_mm({"text": "Корень", "children": [
    {"text": "Ветка 1", "children": [{"text": "Лист 1", "icon": "idea"}, "Лист 2"]},
    "Ветка 2",
]})


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


class TestUnknownArguments(ConverterCase):
    """A mistyped flag must not fall through to a silent regeneration.

    The gate is only worth having if it can be trusted to fail. `--chek` used
    to write the artifact and exit 0, which is a green gate over a mutated tree.
    """

    def setUp(self):
        super().setUp()
        (self.dir / SOURCE_NAME).write_text(ICON_FIXTURE, encoding="utf-8")

    def test_mistyped_flag_is_rejected(self):
        result = self.run_converter("--chek")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)

    def test_mistyped_flag_writes_nothing(self):
        self.run_converter("--chek")
        self.assertFalse(self.out.exists(), "a bad flag must not create the artifact")

    def test_mistyped_flag_alongside_a_real_one_is_rejected(self):
        result = self.run_converter("--check", "--chek")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)

    def test_a_positional_argument_is_rejected(self):
        result = self.run_converter("docs/legacy/out.md")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)


class TestIcons(ConverterCase):
    def setUp(self):
        super().setUp()
        (self.dir / SOURCE_NAME).write_text(ICON_FIXTURE, encoding="utf-8")

    def test_icon_is_preserved(self):
        self.run_converter()
        text = self.out.read_text(encoding="utf-8")
        self.assertIn("idea", text, "icon dropped from the artifact")

    def test_icon_sits_with_its_node(self):
        self.run_converter()
        line = [l for l in self.out.read_text(encoding="utf-8").splitlines()
                if "Лист 1" in l][0]
        self.assertIn("idea", line, "icon is not attached to its own node")

    def test_nodes_without_icons_are_unmarked(self):
        self.run_converter()
        line = [l for l in self.out.read_text(encoding="utf-8").splitlines()
                if "Лист 2" in l][0]
        self.assertEqual(line.strip(), "- Лист 2")

    def test_all_icons_on_one_node_are_kept(self):
        """The real map has a node carrying both a warning and a done mark.
        Keeping only the first icon silently drops half of that node's meaning.
        """
        (self.dir / SOURCE_NAME).write_text(make_mm(
            {"text": "Корень", "children": [
                {"text": "Оба", "icon": ["messagebox_warning", "yes"]},
            ]}), encoding="utf-8")
        self.run_converter()
        line = [l for l in self.out.read_text(encoding="utf-8").splitlines()
                if "Оба" in l][0]
        self.assertIn("messagebox_warning", line)
        self.assertIn("yes", line)

    def test_every_real_map_icon_survives(self):
        """The snapshot exists to preserve the author's own marks, including
        the ones that record a rejected option or an unanswered question.

        Counting occurrences, not just looking for the name: "button_ok"
        appearing once would pass a substring check while 14 of 15 were lost.
        """
        (self.dir / SOURCE_NAME).write_text(
            (REPO / SOURCE_NAME).read_text(encoding="utf-8"), encoding="utf-8")
        result = self.run_converter()
        self.assertEqual(result.returncode, 0, result.stderr)
        produced = self.out.read_text(encoding="utf-8")
        source = (REPO / SOURCE_NAME).read_text(encoding="utf-8")
        wanted = Counter(re.findall(r'BUILTIN="([^"]+)"', source))
        self.assertGreater(len(wanted), 1, "source has no icons; test proves nothing")
        got = Counter(re.findall(r"\[icon:([^\]]+)\]", produced))
        for icon, count in wanted.items():
            # The header documents the marker syntax using a placeholder name
            # that is not a real icon, so no real count is inflated by it.
            self.assertEqual(got.get(icon, 0), count,
                             "icon %r: expected %d, got %d"
                             % (icon, count, got.get(icon, 0)))


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