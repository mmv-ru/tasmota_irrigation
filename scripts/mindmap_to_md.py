#!/usr/bin/env python3
"""Convert the legacy FreeMind map into readable markdown.

Usage: python3 scripts/mindmap_to_md.py [--check]

--check only verifies the committed artifact is up to date (exit 1 on drift),
so the snapshot can be a gate instead of a thing people forget to regenerate.
It never writes.

What survives the conversion: the node's own label, nesting depth, and the
author's icon marks. FreeMind stores a plain label in TEXT and a multi-line (or
formatted) one in <richcontent TYPE="NODE">; both mean the same thing and both
are read here, otherwise whole nodes would vanish silently. A
<richcontent TYPE="NOTE"> is a different animal - a remark about the node, not
its label - and is deliberately skipped.

Icons are kept under their own name (`[icon:idea]`) rather than mapped to a
symbol of our own choosing - the icons are the author's shorthand for
"rejected option" / "open question" / priority, and reinterpreting them here
would quietly edit the source.
"""
import argparse
import datetime
import html
import re
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "Поливалка Arduino.mm"
OUT = ROOT / "docs" / "legacy" / "Поливалка_Arduino.md"
SEP = " · "


def header(created, modified):
    return f"""# Поливалка Arduino — исходная карта (снимок)

> Сгенерировано `scripts/mindmap_to_md.py` из `Поливалка Arduino.mm` (FreeMind, XML).
> **Не редактировать руками.** Правки исходника — в FreeMind, затем регенерация.
> Это исторический источник, а не спецификация: цели проекта вынесены в
> [`../vision.md`](../vision.md), принципы и решения — в
> [`../principles.md`](../principles.md).
>
> Дата создания карты: {created}. Последняя правка: {modified}.
> Метки `[icon:имя]` — иконки автора исходной карты, сохранены как есть.
> Разрывы строк внутри узла свёрнуты в ` · `: одна физическая строка — один
> узел, дерево кодируется только отступом.
"""


def node_text(node):
    """The node's own label, whichever form FreeMind stored it in.

    A multi-line label lands in <richcontent TYPE="NODE"> with no TEXT
    attribute at all, so a converter that reads TEXT only drops the node
    entirely - the failure is invisible in FreeMind, where both look alike.
    """
    plain = html.unescape(node.get("TEXT") or "")
    if plain.strip():
        return one_line(plain.splitlines())
    return rich_text(node)


def one_line(chunks):
    """Join visual lines into the single line this snapshot allows per node.

    Runs of spaces collapse too: HTML would collapse them and markdown renders
    them as one, so keeping them would preserve an illusion of alignment. The
    author's original text stays in the .mm.
    """
    parts = []
    for chunk in chunks:
        line = re.sub(r"\s+", " ", chunk).strip()
        if line:
            parts.append(line)
    return SEP.join(parts)


def rich_text(node):
    """Flatten <richcontent TYPE="NODE"> into a single line.

    Paragraphs and <br/> are the author's line breaks; they become SEP so the
    snapshot keeps one line per node. Other tags (<b>, <i>, ...) carry no text
    of their own and are skipped.
    """
    rich = node.find("richcontent")
    if rich is None or rich.get("TYPE") != "NODE":
        return ""
    body = rich.find("html/body")
    if body is None:
        return ""

    lines = [[]]

    def collect(element):
        if element.text:
            lines[-1].append(element.text)
        for child in element:
            if child.tag == "br":
                lines.append([])
                if child.tail:
                    lines[-1].append(child.tail)
                continue
            if child.tag == "p":
                lines.append([])
            collect(child)
            if child.tag == "p":
                lines.append([])
            if child.tail:
                lines[-1].append(child.tail)

    collect(body)
    return one_line("".join(chunks) for chunks in lines)


def walk(node, depth=-1, out=None):
    """Flatten the node tree into (depth, text) pairs.

    Depth starts at -1 so that the top-level node lands on 0 and render() can
    treat depth 0 as the document heading. <map> itself carries no label.
    A node without a label is skipped, but its children keep their depth.
    """
    if out is None:
        out = []
    text = node_text(node)
    if text:
        out.append((depth, marker(node), text))
    for child in node.findall("node"):
        walk(child, depth + 1, out)
    return out


def marker(node):
    """Render the author's icons under their own names, or nothing if none.

    A node can carry more than one icon (the real map has one carrying both a
    warning and a done mark), so every icon is rendered - keeping only the
    first silently drops the other half of that node's meaning.
    """
    names = [i.get("BUILTIN") or "?" for i in node.findall("icon")]
    if not names:
        return ""
    return "".join("[icon:%s] " % n for n in names)


def render(nodes):
    """Render the flat node list as a nested markdown list.

    The snapshot header already carries the document title, so the tree root is
    rendered as H2 - a second H1 would render as a duplicate title.
    """
    lines = []
    for depth, icon, text in nodes:
        lines.append("  " * depth + ("- " if depth else "## ") + icon + text)
    return "\n".join(lines) + "\n"


def stamp(node, attr):
    """Newest CREATED/MODIFIED timestamp in the map, as YYYY-MM."""
    best = max((int(n.get(attr)) for n in node.iter("node") if n.get(attr)),
               default=None)
    if best is None:
        return "неизвестно"
    when = datetime.datetime.fromtimestamp(best / 1000, datetime.timezone.utc)
    return when.strftime("%Y-%m")


def main():
    parser = argparse.ArgumentParser(
        description="Convert the legacy FreeMind map to markdown.")
    parser.add_argument("--check", action="store_true",
                        help="verify the artifact is up to date; never writes")
    args = parser.parse_args()

    root = ET.parse(SRC).getroot()
    nodes = walk(root)
    body = (header(stamp(root, "CREATED"), stamp(root, "MODIFIED"))
            + "\n" + render(nodes))

    if args.check:
        if not OUT.exists():
            print(f"MISSING: {OUT} — run without --check")
            return 1
        if OUT.read_text(encoding="utf-8") != body:
            print(f"DRIFT: {OUT} is stale — run without --check")
            return 1
        print(f"OK: {OUT.name} up to date ({len(nodes)} nodes)")
        return 0

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(body, encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)} ({len(nodes)} nodes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())