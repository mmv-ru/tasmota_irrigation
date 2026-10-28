#!/usr/bin/env python3
"""Tests for scripts/mindmap_to_md.py.

The converter derives its input and output paths from its own location, so the
tests run it from a temp directory that holds a copy of the script. That keeps
the CLI contract exactly as specified - no extra flags to test around.

Run: python3 scripts/test_mindmap_to_md.py
"""
import html
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
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

    Rich-content forms are spelled out explicitly because FreeMind stores a
    multi-line label outside TEXT, with no TEXT attribute at all:

      "rich": ["абзац", ["строка", "строка"]]  -> <richcontent TYPE="NODE">
      "note": [...]                            -> <richcontent TYPE="NOTE">
      "no_text": True                          -> a node with no label
      "xml": "<...>"                           -> raw markup inside the node

    A nested list is one paragraph whose lines are joined by <br/>. "xml" is
    the escape hatch for markup the structured form cannot express.
    """
    lines = ['<map version="1.1.0">']

    def rich_block(pad, kind, paragraphs):
        block = ['%s<richcontent TYPE="%s"><html><head></head><body>'
                 % (pad, kind)]
        for para in paragraphs:
            para_lines = para if isinstance(para, list) else [para]
            text = "<br />".join(escape(line) for line in para_lines)
            block.append("%s  <p>%s</p>" % (pad, text))
        block.append("%s</body></html></richcontent>" % pad)
        return block

    def emit(current, depth):
        rich = note = None
        raw = ""
        if isinstance(current, str):
            text, icon, children = current, (), ()
        else:
            text = current.get("text")
            raw_icons = current.get("icon", ())
            icon = (raw_icons,) if isinstance(raw_icons, str) else tuple(raw_icons)
            children = current.get("children", ())
            rich = current.get("rich")
            note = current.get("note")
            raw = current.get("xml", "")
        pad = " " * (4 * depth)
        label = "" if text is None else ' TEXT="%s"' % escape(text)
        lines.append("%s<node%s>" % (pad, label))
        if rich is not None:
            lines.extend(rich_block(pad + "  ", "NODE", rich))
        if note is not None:
            lines.extend(rich_block(pad + "  ", "NOTE", note))
        for name in icon:
            lines.append('%s  <icon BUILTIN="%s"/>' % (pad, name))
        if raw:
            lines.append("%s  %s" % (pad, raw))
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


def indent(line):
    """Leading spaces of a rendered line."""
    return len(line) - len(line.lstrip())


def label_head(node):
    """The first line of a node's label, computed independently of the converter.

    Used as a signature: if a node's opening text is absent from the snapshot,
    the node vanished. Deliberately stops at the first visual line, so this
    check knows nothing about how line breaks are rendered.
    """
    plain = html.unescape(node.get("TEXT") or "")
    if plain.strip():
        head = plain.splitlines()[0]
    else:
        rich = node.find("richcontent")
        if rich is None or rich.get("TYPE") != "NODE":
            return ""
        body = rich.find("html/body")
        if body is None:
            return ""
        head = ""
        for para in body.iter("p"):
            head = para.text or ""
            if head.strip():
                break
    return re.sub(r"\s+", " ", head).strip()[:60]


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

    def use_map(self, tree):
        """Replace the default fixture with the given tree."""
        (self.dir / SOURCE_NAME).write_text(make_mm(tree), encoding="utf-8")

    def write_map(self, xml):
        """Replace the default fixture with raw FreeMind XML."""
        (self.dir / SOURCE_NAME).write_text(xml, encoding="utf-8")

    def rendered(self):
        """Convert and return the artifact text."""
        result = self.run_converter()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return self.out.read_text(encoding="utf-8")


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


class TestRichContent(ConverterCase):
    """A multi-line label lives in <richcontent TYPE="NODE">, not in TEXT.

    FreeMind shows both forms identically, so a converter reading TEXT only
    drops the node with no visible symptom. Counts here are fixture counts,
    not properties of the author's map.
    """

    def test_rich_label_is_rendered_and_counted(self):
        self.use_map({"text": "Корень", "children": [
            {"rich": ["Многострочная подпись"]}]})
        result = self.run_converter()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2 nodes", result.stdout)
        self.assertIn("Многострочная подпись",
                      self.out.read_text(encoding="utf-8"))

    def test_paragraph_break_becomes_one_separator(self):
        self.use_map({"text": "Корень", "children": [
            {"rich": ["Первая строка", "Вторая строка"]}]})
        line = [l for l in self.rendered().splitlines()
                if "Первая строка" in l][0]
        text = line.split("- ", 1)[1]
        self.assertEqual(text, "Первая строка · Вторая строка")
        self.assertNotIn("  ", text)

    def test_br_inside_paragraph_and_empty_paragraph(self):
        self.use_map({"text": "Корень", "children": [
            {"rich": [["Один", "Два"], "", "Три"]}]})
        line = [l for l in self.rendered().splitlines() if "Один" in l][0]
        self.assertEqual(line.split("- ", 1)[1], "Один · Два · Три")

    def test_newlines_inside_text_become_separators(self):
        # FreeMind also writes &#xa; into TEXT (4 nodes of the real map do),
        # which would otherwise put a raw newline inside a bullet.
        self.write_map(
            '<map version="1.1.0">\n'
            '  <node TEXT="Корень">\n'
            '    <node TEXT="Строка один&#xa;Строка два"/>\n'
            "  </node>\n"
            "</map>\n")
        line = [l for l in self.rendered().splitlines() if "Строка один" in l][0]
        self.assertEqual(line.split("- ", 1)[1], "Строка один · Строка два")

    def test_multiline_label_keeps_children_under_it(self):
        self.use_map({"text": "Корень", "children": [
            {"rich": ["Родитель", "с переносом"], "children": ["Ребёнок"]}]})
        lines = self.rendered().splitlines()
        parent = [l for l in lines if "Родитель" in l][0]
        child = [l for l in lines if "Ребёнок" in l][0]
        self.assertEqual(indent(child), indent(parent) + 2)

    def test_text_wins_over_a_note(self):
        self.use_map({"text": "Подпись", "note": ["Скрытая заметка"]})
        text = self.rendered()
        self.assertIn("Подпись", text)
        self.assertNotIn("Скрытая заметка", text)

    def test_note_only_node_is_skipped_but_its_children_survive(self):
        self.use_map({"text": "Корень", "children": [
            {"note": ["Только заметка"], "children": ["Ребёнок"]}]})
        text = self.rendered()
        self.assertNotIn("Только заметка", text)
        child = [l for l in text.splitlines() if "Ребёнок" in l][0]
        # Корень is depth 0, the skipped node occupies depth 1, so its child
        # must stay at depth 2 instead of being promoted.
        self.assertEqual(indent(child), 4)

    def test_entities_are_decoded_and_nbsp_collapses(self):
        self.use_map({"text": "Корень", "children": [
            {"no_text": True,
             "xml": '<richcontent TYPE="NODE"><html><head></head><body>'
                    '<p>Границы:&#160;&#8211;25&#160;&#176;C &amp; +100</p>'
                    '</body></html></richcontent>'}]})
        line = [l for l in self.rendered().splitlines() if "Границы" in l][0]
        self.assertEqual(line.split("- ", 1)[1], "Границы: –25 °C & +100")

    def test_formatting_tags_do_not_leak(self):
        self.use_map({"text": "Корень", "children": [
            {"no_text": True,
             "xml": '<richcontent TYPE="NODE"><html><head></head><body>'
                    '<p>Жирный <b>текст</b> и <i>курсив</i></p>'
                    '</body></html></richcontent>'}]})
        line = [l for l in self.rendered().splitlines() if "Жирный" in l][0]
        self.assertIn("Жирный текст и курсив", line)
        self.assertNotIn("<b>", line)
        self.assertNotIn("<i>", line)

    def test_icons_stay_in_front_of_a_multiline_label(self):
        self.use_map({"text": "Корень", "children": [
            {"rich": ["Первый", "Второй"], "icon": ["idea", "button_ok"]}]})
        line = [l for l in self.rendered().splitlines() if "Первый" in l][0]
        self.assertIn("[icon:idea] [icon:button_ok] Первый · Второй", line)


class TestRealMap(ConverterCase):
    """The committed map, checked against itself - no expected node counts.

    A hard-coded "N nodes" turns every edit in FreeMind into a red test, and
    the lesson learned is to bump the number without reading it. What matters
    is that no node disappears and that the shape of the tree survives.
    """

    def setUp(self):
        super().setUp()
        self.source = (REPO / SOURCE_NAME).read_text(encoding="utf-8")
        (self.dir / SOURCE_NAME).write_text(self.source, encoding="utf-8")

    def tree(self):
        return ET.fromstring(self.source)

    def test_no_node_label_vanishes(self):
        result = self.run_converter()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        produced = self.out.read_text(encoding="utf-8")
        nodes = list(self.tree().iter("node"))
        self.assertGreater(len(nodes), 100,
                           "source looks empty; test proves nothing")
        missing = [head for head in (label_head(n) for n in nodes)
                   if head and head not in produced]
        self.assertEqual(missing, [], "nodes lost in conversion: %r"
                         % missing[:5])

    def test_tree_depth_is_preserved(self):
        self.run_converter()
        indents = [indent(l) for l in self.out.read_text(encoding="utf-8").splitlines()
                   if l.lstrip().startswith("- ")]
        self.assertGreater(len(set(indents)), 3,
                           "tree is too shallow to be the real map")

        deepest = 0

        def visit(node, depth):
            nonlocal deepest
            if label_head(node):
                deepest = max(deepest, depth)
            for child in node.findall("node"):
                visit(child, depth + 1)

        for top in self.tree().findall("node"):
            visit(top, 0)
        self.assertEqual(max(indents), 2 * deepest)

    def test_each_top_level_node_is_a_heading(self):
        self.run_converter()
        produced = self.out.read_text(encoding="utf-8").splitlines()
        headings = [l for l in produced if l.startswith("## ")]
        tops = self.tree().findall("node")
        self.assertEqual(len(headings), len(tops),
                         "top-level nodes lost: %r" % headings)
        for top, heading in zip(tops, headings):
            self.assertIn(label_head(top), heading,
                          "heading belongs to another node")


class TestCommittedArtifact(unittest.TestCase):
    """The repo's own snapshot must match the repo's own map.

    This is the drift gate: the map is edited in FreeMind, and nothing else
    would notice a stale artifact. Read-only, and silent about the map size.
    """

    def test_committed_snapshot_is_current(self):
        result = subprocess.run(
            [sys.executable, str(CONVERTER), "--check"],
            cwd=REPO, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("up to date", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)