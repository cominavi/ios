"""Flatten `axe describe-ui` JSON into one line per useful element.

Reads JSON on stdin. By default prints elements that have a label, value or
identifier, or that are interactive; `--all` prints every node. Each line is:

    <Type> "<label>" [value=...] [id=...] @ x,y wxh  center=(cx,cy)

Coordinates are in points of the rendering display, ready for `axe tap -x -y`.
"""

import json
import sys

INTERACTIVE = {"Button", "TextField", "SearchField", "SecureTextField", "Switch",
               "Slider", "Cell", "Link", "Tab", "TabBar", "Toggle", "PopUpButton"}


def walk(node, depth, show_all, out):
    if isinstance(node, list):
        for child in node:
            walk(child, depth, show_all, out)
        return
    kind = node.get("type") or node.get("role") or "?"
    label = node.get("AXLabel")
    value = node.get("AXValue")
    ident = node.get("AXUniqueId")
    frame = node.get("frame") or {}
    w, h = frame.get("width", 0), frame.get("height", 0)
    interesting = label or value or ident or kind in INTERACTIVE
    if show_all or (interesting and w > 0 and h > 0):
        x, y = frame.get("x", 0), frame.get("y", 0)
        parts = ["  " * depth if show_all else "", kind]
        if label:
            parts.append(json.dumps(label, ensure_ascii=False))
        if value:
            parts.append("value=" + json.dumps(value, ensure_ascii=False))
        if ident:
            parts.append("id=" + ident)
        parts.append("@ %g,%g %gx%g  center=(%g,%g)" % (
            round(x, 1), round(y, 1), round(w, 1), round(h, 1),
            round(x + w / 2, 1), round(y + h / 2, 1)))
        out.append(" ".join(p for p in parts if p != ""))
    for child in node.get("children") or []:
        walk(child, depth + 1, show_all, out)


def main():
    show_all = "--all" in sys.argv[1:]
    raw = sys.stdin.read()
    if not raw.strip():
        sys.exit("axe describe-ui returned nothing (is the simulator booted and responsive?)")
    out = []
    walk(json.loads(raw), 0, show_all, out)
    print("\n".join(out))


if __name__ == "__main__":
    main()
