#!/usr/bin/env python3
"""Tool: replace_text. Replace exact occurrences of `old` with `new` in a file
(read-modify-write). Refuses if `old` is empty or absent so an accidental
no-op or a wrong find never silently writes. Writes to disk, so this tool is
`permission: ask` by design."""
import json
import sys


def main():
    try:
        args = json.loads(sys.argv[1])
    except (IndexError, json.JSONDecodeError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return
    try:
        path = args["path"]
        old = args["old"]
        new = args["new"]
    except KeyError as e:
        print(json.dumps({"ok": False, "error": f"missing required argument: {e}"}))
        return

    if old == "":
        print(json.dumps({"ok": False, "error": "old must not be empty"}))
        return

    try:
        count = int(args.get("count", 1))
    except (TypeError, ValueError):
        print(json.dumps({"ok": False, "error": "count must be an integer (-1 = all, else >= 1)"}))
        return
    if count != -1 and count < 1:
        print(json.dumps({"ok": False, "error": "count must be -1 (all) or >= 1"}))
        return

    try:
        with open(path, "r", errors="replace") as f:
            content = f.read()
    except OSError as e:
        print(json.dumps({"ok": False, "error": f"cannot read file: {e}"}))
        return

    total = content.count(old)
    if total == 0:
        print(json.dumps({"ok": False, "error": f"'old' not found in {path}"}))
        return

    if count == -1:
        new_content = content.replace(old, new)
        replaced = total
    else:
        new_content = content.replace(old, new, count)
        replaced = min(count, total)

    try:
        with open(path, "w") as f:
            f.write(new_content)
    except OSError as e:
        print(json.dumps({"ok": False, "error": f"cannot write file: {e}"}))
        return

    print(json.dumps({"ok": True, "data": {
        "path": path,
        "replaced": replaced,
        "total_occurrences": total,
    }}))


if __name__ == "__main__":
    main()
