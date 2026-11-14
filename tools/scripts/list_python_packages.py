#!/usr/bin/env python3
"""Tool: list_python_packages. Args: {"contains": "..."} (optional filter).
Lists installed Python distributions (name + version) via importlib.metadata
directly in-process, so it works even when `pip` is missing or slow, and
avoids needing run_command approval.
"""
import json
import sys

MAX_PACKAGES = 2000


def main():
    try:
        args = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
    except (IndexError, json.JSONDecodeError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return

    contains = (args.get("contains") or "").lower()

    try:
        import importlib.metadata as md
    except ImportError:
        try:
            import importlib.metadata as md  # py3.8+
        except ImportError as e:
            print(json.dumps({"ok": False, "error": f"importlib.metadata unavailable: {e}"}))
            return

    try:
        packages = []
        for dist in md.distributions():
            name = dist.metadata.get("Name", "")
            if not name:
                continue
            if contains and contains not in name.lower():
                continue
            packages.append({"name": name, "version": dist.version})
        packages.sort(key=lambda p: p["name"].lower())

        truncated = len(packages) > MAX_PACKAGES
        print(json.dumps({
            "ok": True,
            "data": {
                "packages": packages[:MAX_PACKAGES],
                "count": len(packages),
                "truncated": truncated,
            },
        }))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
