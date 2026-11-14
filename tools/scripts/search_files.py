#!/usr/bin/env python3
"""Tool: search_files. Recursively search a regex (or fixed string) under a path
and return matching lines with file:line numbers. Wraps system `grep` (no `rg`
installed here) so code search is structured and needs no run_command approval.
Read-only."""
import json
import re
import subprocess
import sys

MAX_OUTPUT = 128 * 1024


def main():
    try:
        args = json.loads(sys.argv[1])
    except (IndexError, json.JSONDecodeError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return
    try:
        pattern = args["pattern"]
    except KeyError:
        print(json.dumps({"ok": False, "error": "pattern is required"}))
        return

    path = args.get("path", ".")
    glob = args.get("glob") or ""
    ignore_case = bool(args.get("ignore_case", False))
    fixed = bool(args.get("fixed", False))
    context = int(args.get("context", 0))
    cb = int(args.get("context_before", 0))
    ca = int(args.get("context_after", 0))
    max_matches = int(args.get("max_matches", 200))
    files_only = bool(args.get("files_with_matches", False))

    if not fixed:
        # Validate the regex locally so a bad pattern is a clean error.
        try:
            re.compile(pattern)
        except re.error as e:
            print(json.dumps({"ok": False, "error": f"invalid regex: {e}"}))
            return

    cmd = ["grep", "-rl", "-I", "--color=never"] if files_only else ["grep", "-rnH", "-I", "--color=never"]
    if ignore_case:
        cmd.append("-i")
    # Default grep is basic regex where '|' is literal; -P gives the expected regex syntax.
    cmd.append("-F" if fixed else "-P")
    if not files_only:
        if context > 0:
            cmd += ["-C", str(context)]
        else:
            if cb > 0:
                cmd += ["-B", str(cb)]
            if ca > 0:
                cmd += ["-A", str(ca)]
    if glob:
        cmd += ["--include", glob]
    cmd += ["--", pattern, path]

    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired:
        print(json.dumps({"ok": False, "error": "search timed out"}))
        return
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))
        return

    # grep: 0 = matches, 1 = no matches (both fine), >=2 = real error.
    if proc.returncode >= 2:
        err = (proc.stderr or "").strip() or f"grep exit {proc.returncode}"
        print(json.dumps({"ok": False, "error": err}))
        return

    # max_matches counts matching lines only; context lines come along free.
    lines = []
    count = 0
    truncated = False
    for ln in (proc.stdout or "").splitlines():
        if files_only or re.match(r"^.*?:\d+:", ln):
            if count >= max_matches:
                truncated = True
                break
            count += 1
        lines.append(ln)
    joined = "\n".join(lines)
    if len(joined) > MAX_OUTPUT:
        joined = joined[:MAX_OUTPUT] + "\n...(output truncated)"
        truncated = True

    print(json.dumps({"ok": True, "data": {
        "pattern": pattern,
        "path": path,
        "matches": joined,
        "count": count,
        "truncated": truncated,
    }}))


if __name__ == "__main__":
    main()
