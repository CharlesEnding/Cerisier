#!/usr/bin/env python3
"""Tool: list_processes. List running processes (like `ps -A`) and filter them
with a grep-style pattern, without needing run_command approval.

This is the dedicated, no-approval alternative to `ps aux | grep ...`.

Design notes:
  * `ps` is invoked with a list of arguments (no shell), so `pattern` is
    matched in Python and never reaches a shell -- there is no injection
    surface, the same no-shell approach as git_read.
  * Filtering happens in Python rather than through a real `grep` process, so
    (unlike `ps aux | grep foo`) the filter never matches its own grep line.
  * The pattern is matched against the *whole rendered line* (pid, user, %cpu,
    %mem, stat, command), which is exactly what `ps aux | grep` sees, so it
    can hit the command, the user name, a pid, etc.
"""
import json
import re
import subprocess
import sys

DEFAULT_MAX_MATCHES = 100

# Column order for `ps -o`. Every field before `command` is guaranteed to be a
# single whitespace-free token (pid, user, %cpu, %mem, stat); `command` is last
# and may contain spaces, so we split with maxsplit and keep the rest as-is.
PS_COLUMNS = "pid,user,%cpu,%mem,stat,command"


def build_command():
    # -A: all processes. -ww: unlimited command width (procps treats two -w
    # flags as "no truncation", important so grep matches long command lines).
    # -o: explicit columns. procps-ng `ps` (the one on this host).
    return ["ps", "-A", "-ww", "-o", PS_COLUMNS]


def parse_line(line):
    """Turn a `ps` output line into a structured record.

    Returns None for a short/malformed line. `command` (the 6th field) keeps
    any internal whitespace because split(maxsplit=5) stops after 5 splits.
    """
    parts = line.split(maxsplit=5)
    if len(parts) < 6:
        return None
    pid, user, cpu, mem, stat, command = parts
    try:
        pid_int = int(pid)
    except ValueError:
        return None
    return {
        "pid": pid_int,
        "user": user,
        "cpu": cpu,
        "mem": mem,
        "stat": stat,
        "command": command,
    }


def main():
    try:
        args = json.loads(sys.argv[1])
    except (IndexError, json.JSONDecodeError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return

    pattern = args.get("pattern") or ""
    ignore_case = bool(args.get("ignore_case", False))
    fixed = bool(args.get("fixed", False))
    invert = bool(args.get("invert", False))
    try:
        max_matches = int(args.get("max_matches", DEFAULT_MAX_MATCHES))
        max_matches = max(max_matches, 1)
    except (TypeError, ValueError):
        max_matches = DEFAULT_MAX_MATCHES

    try:
        proc = subprocess.run(build_command(), capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired:
        print(json.dumps({"ok": False, "error": "ps timed out"}))
        return
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))
        return

    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        print(json.dumps({"ok": False, "error": f"ps failed (exit {proc.returncode}): {err}"}))
        return

    lines = proc.stdout.splitlines()
    if len(lines) <= 1:
        # Only the header (or nothing): no processes to report.
        print(json.dumps({"ok": True, "data": {
            "pattern": pattern, "processes": [], "count": 0,
            "total_matched": 0, "truncated": False,
        }}))
        return

    body = lines[1:]  # drop the column header

    # Compile the matcher against the whole line, mirroring `ps ... | grep`.
    matcher = None
    if pattern:
        flags = re.IGNORECASE if ignore_case else 0
        if fixed:
            matcher = re.compile(re.escape(pattern), flags)
        else:
            try:
                matcher = re.compile(pattern, flags)
            except re.error as e:
                print(json.dumps({"ok": False, "error": f"invalid regex: {e}"}))
                return

    processes = []
    total_matched = 0
    for line in body:
        if not line.strip():
            continue
        if matcher is not None:
            matched = matcher.search(line) is not None
        else:
            matched = True
        if invert:
            matched = not matched
        if not matched:
            continue
        total_matched += 1
        if len(processes) < max_matches:
            rec = parse_line(line)
            if rec is not None:
                processes.append(rec)

    truncated = total_matched > len(processes)

    print(json.dumps({"ok": True, "data": {
        "pattern": pattern,
        "processes": processes,
        "count": len(processes),
        "total_matched": total_matched,
        "truncated": truncated,
    }}))


if __name__ == "__main__":
    main()
