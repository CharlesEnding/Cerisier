#!/usr/bin/env python3
"""Tool: list_dir. Args: {"path": "...", "show_hidden": bool, "max_entries": int}.
Lists the immediate entries of a directory (non-recursive) as structured data,
so the agent can see the filesystem without needing run_command approval.
"""
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
    show_hidden = bool(args.get("show_hidden", False))
    max_entries = int(args.get("max_entries", 200))

    try:
        if not os.path.isdir(path):
            print(json.dumps({"ok": False, "error": f"not a directory: {path}"}))
            return
        names = os.listdir(path)
        if not show_hidden:
            names = [n for n in names if not n.startswith(".")]
        names.sort()

        entries = []
        for name in names[:max_entries]:
            full = os.path.join(path, name)
            if os.path.isdir(full):
                kind = "dir"
                size = 0
            elif os.path.islink(full):
                kind = "link"
                size = 0
            else:
                kind = "file"
                try:
                    size = os.path.getsize(full)
                except OSError:
                    size = 0
            entries.append({"name": name, "type": kind, "size": size})

        print(json.dumps({
            "ok": True,
            "data": {
                "path": path,
                "entries": entries,
                "count": len(entries),
                "truncated": len(names) > max_entries,
            },
        }))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
