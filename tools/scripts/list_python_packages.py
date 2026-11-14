#!/usr/bin/env python3
"""Tool: list_python_packages. Args: {"names": ["..."]} or {"all": true}.
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

    names = args.get("names") or []
    if isinstance(names, str):
        names = [names]
    names = [n.lower() for n in names if isinstance(n, str) and n]
    want_all = bool(args.get("all"))
    if not names and not want_all:
        print(json.dumps({"ok": False, "error": "pass `names` (list of substrings) or `all: true`"}))
        return

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
        matched = set()
        for dist in md.distributions():
            name = dist.metadata.get("Name", "")
            if not name:
                continue
            lname = name.lower()
            if not want_all:
                hits = [n for n in names if n in lname]
                if not hits:
                    continue
                matched.update(hits)
            packages.append({"name": name, "version": dist.version})
        packages.sort(key=lambda p: p["name"].lower())
        not_found = [] if want_all else [n for n in names if n not in matched]

        truncated = len(packages) > MAX_PACKAGES
        print(json.dumps({
            "ok": True,
            "data": {
                "packages": packages[:MAX_PACKAGES],
                "count": len(packages),
                "not_found": not_found,
                "truncated": truncated,
            },
        }))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
