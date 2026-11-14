#!/usr/bin/env python3
"""Tool: git_read. Read-only git inspection: status, diff, log, show, branch.
Invokes `git` with list arguments (no shell) so there is no injection surface,
and never touches the working tree or index. A non-zero `exit_code` means the
git command itself failed (e.g. not a repo); the error text is in `output`."""
import json
import subprocess
import sys

MAX_OUTPUT = 128 * 1024


def build(action, repo, path, ref, limit):
    base = ["git", "-C", repo]
    if action == "status":
        return base + ["status", "--porcelain"]
    if action == "diff":
        cmd = base + ["diff"]
        if path:
            cmd += ["--", path]
        return cmd
    if action == "log":
        cmd = base + ["log", "--oneline", "--no-decorate", "-n", str(limit)]
        if path:
            cmd += ["--", path]
        return cmd
    if action == "show":
        if not ref:
            raise ValueError("ref is required for 'show'")
        # Refs come BEFORE `--` so git treats them as refs, not paths.
        # Refs starting with '-' would be parsed as flags by git; reject them
        # so a caller can't smuggle in `--help`, `--output`, etc.
        if ref.startswith("-"):
            raise ValueError("'ref' must not start with '-' (looks like a flag)")
        cmd = base + ["show", "--stat", "--no-decorate", ref]
        if path:
            cmd += ["--", path]
        else:
            # Trailing `--` still separates args and ensures git sees no more
            # options after `ref`; harmless when no path is given.
            cmd += ["--"]
        return cmd
    if action == "branch":
        return base + ["branch", "-a"]
    raise ValueError(f"unknown action: {action}")


def main():
    try:
        args = json.loads(sys.argv[1])
    except (IndexError, json.JSONDecodeError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return
    try:
        action = args["action"]
    except KeyError:
        print(json.dumps({"ok": False, "error": "action is required (status|diff|log|show|branch)"}))
        return

    repo = args.get("repo", ".")
    path = args.get("path") or ""
    ref = args.get("ref") or ""
    try:
        limit = int(args.get("limit", 20))
        limit = max(limit, 1)
    except (TypeError, ValueError):
        limit = 20

    try:
        cmd = build(action, repo, path, ref, limit)
    except ValueError as e:
        print(json.dumps({"ok": False, "error": str(e)}))
        return

    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired:
        print(json.dumps({"ok": False, "error": "git timed out"}))
        return
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))
        return

    out = (proc.stdout or "") + (proc.stderr or "")
    truncated = False
    if len(out) > MAX_OUTPUT:
        out = out[:MAX_OUTPUT] + "\n...(output truncated)"
        truncated = True

    print(json.dumps({"ok": True, "data": {
        "action": action,
        "repo": repo,
        "output": out,
        "exit_code": proc.returncode,
        "truncated": truncated,
    }}))


if __name__ == "__main__":
    main()
