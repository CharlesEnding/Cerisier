#!/usr/bin/env python3
"""Tool: run_command. Args: {"command": "..."}. Runs the command through
the shell and returns captured stdout+stderr, truncated. No sandboxing."""
import json
import subprocess
import sys

MAX_OUTPUT = 64 * 1024


def main():
    try:
        args = json.loads(sys.argv[1])
        command = args["command"]
    except (IndexError, KeyError, json.JSONDecodeError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return

    try:
        proc = subprocess.run(
            command, shell=True, capture_output=True, text=True, timeout=25
        )
        output = (proc.stdout or "") + (proc.stderr or "")
        if len(output) > MAX_OUTPUT:
            output = output[:MAX_OUTPUT] + "\n...(truncated)"
        print(json.dumps({
            "ok": True,
            "data": {"exit_code": proc.returncode, "output": output},
        }))
    except subprocess.TimeoutExpired:
        print(json.dumps({"ok": False, "error": "command timed out"}))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
