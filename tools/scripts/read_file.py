#!/usr/bin/env python3
"""Tool: read_file. Args: {"path": "..."}. Reads the given path as-is, no
sandboxing/path-traversal checks (the approval gate is the safety net)."""
import json
import sys

MAX_BYTES = 1024 * 1024


def main():
    try:
        args = json.loads(sys.argv[1])
        path = args["path"]
    except (IndexError, KeyError, json.JSONDecodeError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return

    try:
        with open(path, "r", errors="replace") as f:
            content = f.read(MAX_BYTES + 1)
        truncated = len(content) > MAX_BYTES
        if truncated:
            content = content[:MAX_BYTES]
        print(json.dumps({
            "ok": True,
            "data": {"content": content, "truncated": truncated},
        }))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
