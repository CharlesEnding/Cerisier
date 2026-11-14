#!/usr/bin/env python3
"""Tool: write_tmp_file. Args: {"name": "...", "content": "..."}. Writes under
/tmp/cerisier/ only; names that escape that directory are rejected, so no
approval is needed."""
import json
import os
import sys

BASE = "/tmp/cerisier"


def main():
    try:
        args = json.loads(sys.argv[1])
        name = args["name"]
        content = args["content"]
    except (IndexError, KeyError, json.JSONDecodeError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return

    path = os.path.realpath(os.path.join(BASE, name.lstrip("/")))
    if not path.startswith(os.path.realpath(BASE) + os.sep):
        print(json.dumps({"ok": False, "error": f"name must stay inside {BASE}"}))
        return

    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(content)
        print(json.dumps({
            "ok": True,
            "data": {"path": path, "bytes_written": len(content.encode("utf-8"))},
        }))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
