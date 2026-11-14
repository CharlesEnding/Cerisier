#!/usr/bin/env python3
"""Tool: pdf_extract_pages. Copy selected pages into a new PDF.

Args: {"input_path": "...", "output_path": "...", "pages": "<1-based range>"}
`pages` is a 1-based range string like "1-3,5,7-9". Writes the selected pages
(keeping order as given) to `output_path` (no sandboxing); returns the output
path, the number of pages extracted, and the source page count.
"""
import json
import os
import sys
import warnings

warnings.filterwarnings("ignore", category=Warning)


def parse_pages(spec, total):
    """Turn a 1-based range string into a list of 0-based page indices."""
    out = []
    for part in str(spec).split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, _, b = part.partition("-")
            a = int(a) if a.strip() else 1
            b = int(b) if b.strip() else total
        else:
            a = b = int(part)
        for i in range(a, b + 1):
            idx = i - 1
            if 0 <= idx < total:
                out.append(idx)
    return out


def main():
    try:
        args = json.loads(sys.argv[1])
        input_path = args["input_path"]
        output_path = args["output_path"]
        pages_spec = args["pages"]
    except (IndexError, KeyError, json.JSONDecodeError, ValueError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return

    try:
        import pypdf
    except ImportError:
        print(json.dumps({"ok": False, "error": "pypdf is not installed"}))
        return

    try:
        reader = pypdf.PdfReader(input_path)
        total = len(reader.pages)
        indices = parse_pages(pages_spec, total)
        if not indices:
            print(json.dumps({"ok": False, "error": "no valid pages selected"}))
            return
        writer = pypdf.PdfWriter()
        for idx in indices:
            writer.add_page(reader.pages[idx])
        parent = os.path.dirname(output_path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(output_path, "wb") as f:
            writer.write(f)
        print(json.dumps({
            "ok": True,
            "data": {
                "output_path": output_path,
                "pages": len(indices),
                "total_pages": total,
            },
        }))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
