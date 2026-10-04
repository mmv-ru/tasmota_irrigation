#!/usr/bin/env python3
"""Convert the legacy FreeMind map into readable markdown.

Usage: python3 scripts/mindmap_to_md.py [--check]

--check only verifies the committed artifact is up to date (exit 1 on drift),
so the snapshot can be a gate instead of a thing people forget to regenerate.
It never writes.

What survives the conversion: node TEXT, nesting depth, and the author's icon
marks. Icons are kept under their own name (`[icon:idea]`) rather than mapped
to a symbol of our own choosing - the icons are the author's shorthand for
"rejected option" / "open question" / priority, and reinterpreting them here
would quietly edit the source.
"""
import argparse
import datetime
import html
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "Поливалка Arduino.mm"
OUT = ROOT / "docs" / "legacy" / "Поливалка_Arduino.md"


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
"""


def walk(node, depth=-1, out=None):
    """Flatten the node tree into (depth, text) pairs.

    Depth starts at -1 so that the top-level node lands on 0 and render() can
    treat depth 0 as the document heading. <map> itself carries no TEXT.
    """
    if out is None:
        out = []
    text = html.unescape(node.get("TEXT") or "").strip()
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