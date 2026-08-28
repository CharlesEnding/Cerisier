#!/usr/bin/env python3
"""Tool: write_file. Args: {"path": "...", "content": "..."}. Writes the
given path as-is, no sandboxing/path-traversal checks (the approval gate
is the safety net). Creates parent directories as needed."""
import json
import os
import sys


def main():
    try:
        args = json.loads(sys.argv[1])
        path = args["path"]
        content = args["content"]
    except (IndexError, KeyError, json.JSONDecodeError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return

    try:
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(path, "w") as f:
            f.write(content)
        print(json.dumps({
            "ok": True,
            "data": {"bytes_written": len(content.encode("utf-8"))},
        }))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
