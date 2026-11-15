#!/usr/bin/env python3
"""Tool: read_tmp_file. Args: {"name": "...", "offset": int, "length": int,
"line_numbers": bool, "start_line": int, "end_line": int}. Reads a file under
/tmp/cerisier/ only; names that escape that directory are rejected, so no
approval is needed. Replaces shell file reading for scratch files, so never use
run_command for it: `cat f` -> name only; `sed -n 'N,Mp' f` -> start_line=N,
end_line=M; `head -n N f` -> end_line=N; `cat -n f` -> line_numbers=true;
`head -c N f` / `tail -c +N f` -> length / offset (bytes). Line ranges are
1-based and inclusive. Reads in binary mode so `offset`/`length` are byte offsets."""
import json
import os
import sys

BASE = "/tmp/cerisier"
MAX_BYTES = 1024 * 1024


def _resolve(name):
    """Return the real path under BASE for `name`, or None if it escapes."""
    path = os.path.realpath(os.path.join(BASE, name.lstrip("/")))
    if path != os.path.realpath(BASE) and not path.startswith(os.path.realpath(BASE) + os.sep):
        return None
    return path


def main():
    try:
        args = json.loads(sys.argv[1])
        name = args["name"]
    except (IndexError, KeyError, json.JSONDecodeError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return

    path = _resolve(name)
    if path is None:
        print(json.dumps({"ok": False, "error": f"name must stay inside {BASE}"}))
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

    if args.get("start_line") or args.get("end_line"):
        try:
            start = max(int(args.get("start_line") or 1), 1)
            end = int(args.get("end_line") or 0)
            with open(path, "rb") as f:
                all_lines = f.read(MAX_BYTES * 8).decode("utf-8", errors="replace").split("\n")
        except Exception as e:
            print(json.dumps({"ok": False, "error": str(e)}))
            return
        end = len(all_lines) if end <= 0 else min(end, len(all_lines))
        picked = all_lines[start - 1:end]
        if line_numbers:
            picked = [f"{start + i}: {ln}" for i, ln in enumerate(picked)]
        content = "\n".join(picked)
        truncated = len(content) > MAX_BYTES
        print(json.dumps({"ok": True, "data": {"content": content[:MAX_BYTES], "truncated": truncated}}))
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
