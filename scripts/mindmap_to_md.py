#!/usr/bin/env python3
"""Convert the legacy FreeMind map into readable markdown.

Usage: python3 scripts/mindmap_to_md.py [--check]

--check only verifies the committed artifact is up to date (exit 1 on drift),
so the snapshot can be a gate instead of a thing people forget to regenerate.
"""
import html
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "Поливалка Arduino.mm"
OUT = ROOT / "docs" / "legacy" / "Поливалка_Arduino.md"

HEADER = """# Поливалка Arduino — исходная карта (снимок)

> Сгенерировано `scripts/mindmap_to_md.py` из `Поливалка Arduino.mm` (FreeMind, XML).
> **Не редактировать руками.** Правки исходника — в FreeMind, затем регенерация.
> Это исторический источник, а не спецификация: цели проекта вынесены в
> `docs/vision.md`, принципы и решения — в `docs/principles.md`.
>
> Дата создания карты: 2020-03. Последняя правка: 2023-08.
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
        out.append((depth, text))
    for child in node.findall("node"):
        walk(child, depth + 1, out)
    return out


def render(nodes):
    """Render the flat node list as a nested markdown list.

    The snapshot header already carries the document title, so the tree root is
    rendered as H2 - a second H1 would render as a duplicate title.
    """
    lines = []
    for depth, text in nodes:
        lines.append("  " * depth + ("- " if depth else "## ") + text)
    return "\n".join(lines) + "\n"


def main():
    root = ET.parse(SRC).getroot()
    nodes = walk(root)
    body = HEADER + "\n" + render(nodes)

    if "--check" in sys.argv:
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
    sys.exit(main())