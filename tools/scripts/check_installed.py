#!/usr/bin/env python3
"""Tool: check_installed. Args: {"name": "..."} for a command/program name.
Looks up the program on PATH (equivalent to `command -v <name>` / `which`)
and reports whether it is installed and where, without needing run_command
approval.
"""
import json
import shutil
import sys


def main():
    try:
        args = json.loads(sys.argv[1])
    except (IndexError, json.JSONDecodeError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return

    try:
        name = args["name"]
        if not name:
            print(json.dumps({"ok": False, "error": "name is required"}))
            return
        path = shutil.which(name) or ""
        print(json.dumps({
            "ok": True,
            "data": {
                "name": name,
                "found": bool(path),
                "path": path,
            },
        }))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
