#!/usr/bin/env python3
"""ask_question stub — the answer is captured server-side via the WebSocket
`tool_call_answer` message, so this script is never actually executed.
It exists to satisfy the manifest's entrypoint requirement."""
import json, sys

def main():
    try:
        args = json.loads(sys.argv[1])
    except (IndexError, json.JSONDecodeError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return
    # Should never reach here: the server short-circuits with tool_call_answer.
    print(json.dumps({"ok": False, "error": "ask_question is handled at the server level, not via script"}))

if __name__ == "__main__":
    main()
