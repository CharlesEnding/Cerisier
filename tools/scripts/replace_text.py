#!/usr/bin/env python3
"""Tool: replace_text. Replace text in a file (read-modify-write).
Two modes: (1) exact substring via `old`; (2) block delimited by `start_line`
and `end_line` (verbatim first/last line of the block). Refuses if the target
is absent so an accidental no-op or a wrong find never silently writes.
Writes to disk, so this tool is `permission: ask` by design."""
import difflib
import json
import sys


def find_line_blocks(content, start_line, end_line):
    """Find all (start_idx, end_idx) line-index pairs where content has
    a block delimited by start_line and end_line (inclusive, exact match
    on the full line content)."""
    lines = content.split("\n")
    blocks = []
    i = 0
    while i < len(lines):
        if lines[i] == start_line:
            for j in range(i, len(lines)):
                if lines[j] == end_line:
                    blocks.append((i, j))
                    i = j + 1
                    break
            else:
                # start_line found but no matching end_line after it
                return None
        else:
            i += 1
    return blocks


def closest_hint(content, old):
    """Locate the file region most similar to `old` and describe how it differs."""
    lines = content.split("\n")
    olines = old.split("\n")
    n = len(olines)
    target = [l.strip() for l in olines]
    stripped = [l.strip() for l in lines]
    starts = range(max(1, len(lines) - n + 1))
    # Cheap line-equality pass narrows the windows before the costlier character comparison.
    scores = [sum(a == b for a, b in zip(target, stripped[i:i + n])) for i in starts]
    top = max(scores)
    candidates = [i for i in starts if scores[i] == top] if top > 0 else list(starts)
    sm = difflib.SequenceMatcher(None, autojunk=False)
    sm.set_seq2("\n".join(target))
    best, best_i = 0.0, -1
    for i in candidates:
        sm.set_seq1("\n".join(stripped[i:i + n]))
        if sm.real_quick_ratio() <= best or sm.quick_ratio() <= best:
            continue
        r = sm.ratio()
        if r > best:
            best, best_i = r, i
    if best_i < 0 or best < 0.6:
        return ""
    a, b = best_i + 1, min(best_i + n, len(lines))
    where = f"line {a}" if a == b else f"lines {a}-{b}"
    if best == 1.0:
        return f" {where.capitalize()} match except for whitespace or indentation; copy them exactly."
    diff = list(difflib.unified_diff(olines, lines[best_i:best_i + n], n=1, lineterm=""))[2:]
    if len(diff) > 40:
        diff = diff[:40] + ["..."]
    return (f" Closest match is {where} ({int(best * 100)}% similar). "
            "Diff from your old (-) to the file (+):\n" + "\n".join(diff))


def main():
    try:
        args = json.loads(sys.argv[1])
    except (IndexError, json.JSONDecodeError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return
    try:
        path = args["path"]
        new = args["new"]
    except KeyError as e:
        print(json.dumps({"ok": False, "error": f"missing required argument: {e}"}))
        return

    old = args.get("old")
    start_line = args.get("start_line")
    end_line = args.get("end_line")

    # Validate locator mode: exactly one of (old) or (start_line + end_line)
    if old is not None and (start_line is not None or end_line is not None):
        print(json.dumps({"ok": False, "error": "Provide either 'old' or 'start_line'+'end_line', not both."}))
        return
    if start_line is not None and end_line is None:
        print(json.dumps({"ok": False, "error": "start_line requires end_line."}))
        return
    if end_line is not None and start_line is None:
        print(json.dumps({"ok": False, "error": "end_line requires start_line."}))
        return
    if old is None and start_line is None:
        print(json.dumps({"ok": False, "error": "Provide 'old' or both 'start_line' and 'end_line'."}))
        return
    if old is not None and old == "":
        print(json.dumps({"ok": False, "error": "old must not be empty."}))
        return

    try:
        count = int(args.get("count", 1))
    except (TypeError, ValueError):
        print(json.dumps({"ok": False, "error": "count must be an integer (-1 = all, else >= 1)"}))
        return
    if count != -1 and count < 1:
        print(json.dumps({"ok": False, "error": "count must be -1 (all) or >= 1"}))
        return

    try:
        with open(path, "r", errors="replace") as f:
            content = f.read()
    except OSError as e:
        print(json.dumps({"ok": False, "error": f"cannot read file: {e}"}))
        return

    if old is not None:
        # --- Mode 1: exact substring ---
        total = content.count(old)
        if total == 0:
            hint = closest_hint(content, old)
            print(json.dumps({"ok": False, "error": f"'old' not found in {path}.{hint}"}))
            return
        if count == -1:
            new_content = content.replace(old, new)
            replaced = total
        else:
            new_content = content.replace(old, new, count)
            replaced = min(count, total)
    else:
        # --- Mode 2: start_line / end_line block ---
        blocks = find_line_blocks(content, start_line, end_line)
        if blocks is None:
            hint = closest_hint(content, start_line)
            print(json.dumps({"ok": False, "error": f"start_line found but no matching end_line after it in {path}.{hint}"}))
            return
        total = len(blocks)
        if total == 0:
            hint = closest_hint(content, start_line)
            print(json.dumps({"ok": False, "error": f"start_line not found in {path}.{hint}"}))
            return

        to_replace = total if count == -1 else min(count, total)
        lines = content.split("\n")
        # Replace from bottom to top so earlier indices don't shift
        selected = blocks[:to_replace]
        selected_sorted = sorted(selected, key=lambda b: b[0], reverse=True)
        for (si, ei) in selected_sorted:
            lines[si:ei + 1] = new.split("\n")
        new_content = "\n".join(lines)
        replaced = to_replace

    try:
        with open(path, "w") as f:
            f.write(new_content)
    except OSError as e:
        print(json.dumps({"ok": False, "error": f"cannot write file: {e}"}))
        return

    print(json.dumps({"ok": True, "data": {
        "path": path,
        "replaced": replaced,
        "total_occurrences": total,
    }}))


if __name__ == "__main__":
    main()
