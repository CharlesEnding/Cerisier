#!/usr/bin/env python3
"""Tool: pdf_to_text. Extract text from a PDF into a plain-text file.

Args: {"input_path": "...", "output_path": "...", "pages": "<optional range>",
       "page_breaks": <optional bool, default true>}
`pages` is a 1-based range string like "1-3,5,7-9"; omitted means all pages.
`page_breaks` inserts a "--- page N ---" separator and a blank line between
pages. Writes the extracted text to `output_path` (no sandboxing); returns the
path and a byte/char count, never the text itself.
"""
import json
import sys
import warnings

warnings.filterwarnings("ignore", category=Warning)
import os


def parse_pages(spec, total):
    """Turn a 1-based range string into a list of 0-based page indices."""
    if not spec:
        return list(range(total))
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
            if 0 <= idx < total and idx not in out:
                out.append(idx)
    return out


def main():
    try:
        args = json.loads(sys.argv[1])
        input_path = args["input_path"]
        output_path = args["output_path"]
        pages_spec = args.get("pages")
        page_breaks = bool(args.get("page_breaks", True))
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
        blocks = []
        for idx in indices:
            text = reader.pages[idx].extract_text() or ""
            if page_breaks:
                blocks.append(f"--- page {idx + 1} ---\n\n{text}")
            else:
                blocks.append(text)
        content = "\n\n".join(blocks)

        parent = os.path.dirname(output_path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(content)

        print(json.dumps({
            "ok": True,
            "data": {
                "output_path": output_path,
                "pages_extracted": len(indices),
                "total_pages": total,
                "characters": len(content),
            },
        }))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
