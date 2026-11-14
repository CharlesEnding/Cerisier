#!/usr/bin/env python3
"""Tool: render_tree. Render a depth-capped, entry-capped directory tree as indented
text (directories suffixed with '/'). The natural complement to list_dir, which
is flat and non-recursive. Read-only."""
import json
import os
import sys


def main():
    try:
        args = json.loads(sys.argv[1])
    except (IndexError, json.JSONDecodeError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return

    path = args.get("path", ".")
    try:
        max_depth = int(args.get("max_depth", 3))
        max_entries = int(args.get("max_entries", 200))
    except (TypeError, ValueError):
        print(json.dumps({"ok": False, "error": "max_depth/max_entries must be integers"}))
        return
    show_hidden = bool(args.get("show_hidden", False))
    dirs_only = bool(args.get("dirs_only", False))

    if not os.path.isdir(path):
        print(json.dumps({"ok": False, "error": f"not a directory: {path}"}))
        return

    lines = []
    state = {"count": 0, "truncated": False}

    # Root label (counted against max_entries).
    root_label = os.path.basename(os.path.abspath(path)) or path
    lines.append(root_label)
    state["count"] += 1

    def walk(current, depth):
        if depth > max_depth:
            return
        try:
            entries = list(os.scandir(current))
        except OSError:
            return
        if not show_hidden:
            entries = [e for e in entries if not e.name.startswith(".")]
        if dirs_only:
            entries = [e for e in entries if e.is_dir(follow_symlinks=False)]
        entries.sort(key=lambda e: (not e.is_dir(follow_symlinks=False), e.name.lower()))
        for e in entries:
            if state["count"] >= max_entries:
                state["truncated"] = True
                return
            is_dir = e.is_dir(follow_symlinks=False)
            lines.append("  " * depth + e.name + ("/" if is_dir else ""))
            state["count"] += 1
            if is_dir:
                walk(e.path, depth + 1)

    walk(path, 1)

    print(json.dumps({"ok": True, "data": {
        "path": path,
        "tree": "\n".join(lines),
        "count": state["count"],
        "truncated": state["truncated"],
    }}))


if __name__ == "__main__":
    main()
