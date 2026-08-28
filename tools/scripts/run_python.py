#!/usr/bin/env python3
"""Tool: run_python. Args: {"code": "..."}. Runs the given code as a
separate `python3 -c` subprocess (keeps failures/timeouts isolated from
this runner) and returns captured stdout+stderr, truncated. No sandboxing."""
import json
import subprocess
import sys

MAX_OUTPUT = 64 * 1024


def main():
    try:
        args = json.loads(sys.argv[1])
        code = args["code"]
    except (IndexError, KeyError, json.JSONDecodeError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return

    try:
        proc = subprocess.run(
            ["python3", "-c", code], capture_output=True, text=True, timeout=25
        )
        output = (proc.stdout or "") + (proc.stderr or "")
        if len(output) > MAX_OUTPUT:
            output = output[:MAX_OUTPUT] + "\n...(truncated)"
        print(json.dumps({
            "ok": True,
            "data": {"exit_code": proc.returncode, "output": output},
        }))
    except subprocess.TimeoutExpired:
        print(json.dumps({"ok": False, "error": "code timed out"}))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
