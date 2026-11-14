#!/usr/bin/env python3
"""Tool: read_local_file. Args: {"path": "...", "offset": int, "length": int,
"line_numbers": bool}. Reads a file (optionally a byte range) as-is, no
sandboxing/path-traversal checks (the approval gate is the safety net). Reads
in binary mode so `offset`/`length` are byte offsets."""
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
        offset = int(args.get("offset", 0))
        offset = max(offset, 0)
        length = int(args.get("length", MAX_BYTES))
        length = MAX_BYTES if length <= 0 else min(length, MAX_BYTES)
        line_numbers = bool(args.get("line_numbers", False))
    except (TypeError, ValueError) as e:
        print(json.dumps({"ok": False, "error": f"invalid numeric argument: {e}"}))
        return

    try:
        # The returned slice's first line number: count newlines before offset.
        base_line = 1
        if line_numbers and offset > 0:
            with open(path, "rb") as f:
                f.seek(0)
                prefix = f.read(offset)
                base_line = prefix.count(b"\n") + 1
        with open(path, "rb") as f:
            if offset:
                f.seek(offset)
            probe = f.read(length + 1)
        truncated = len(probe) > length
        content = probe[:length].decode("utf-8", errors="replace")
        if line_numbers:
            content = "\n".join(
                f"{base_line + i}: {ln}" for i, ln in enumerate(content.split("\n"))
            )
        print(json.dumps({
            "ok": True,
            "data": {"content": content, "truncated": truncated},
        }))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
