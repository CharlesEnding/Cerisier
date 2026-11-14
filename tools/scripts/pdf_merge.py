#!/usr/bin/env python3
"""Tool: pdf_merge. Merge several PDFs into one.

Args: {"input_paths": ["...", "...", ...], "output_path": "..."}
Appends each input PDF (in order) into a single output PDF. Writes to
`output_path` (no sandboxing); returns the output path, the merged page count,
and the number of source files, never the PDF bytes.
"""
import json
import os
import sys
import warnings

warnings.filterwarnings("ignore", category=Warning)


def main():
    try:
        args = json.loads(sys.argv[1])
        input_paths = args["input_paths"]
        output_path = args["output_path"]
    except (IndexError, KeyError, json.JSONDecodeError, ValueError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return

    if not isinstance(input_paths, list) or not input_paths:
        print(json.dumps({"ok": False, "error": "input_paths must be a non-empty list"}))
        return

    try:
        import pypdf
    except ImportError:
        print(json.dumps({"ok": False, "error": "pypdf is not installed"}))
        return

    try:
        writer = pypdf.PdfWriter()
        for p in input_paths:
            writer.append(p)
        parent = os.path.dirname(output_path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(output_path, "wb") as f:
            writer.write(f)
        print(json.dumps({
            "ok": True,
            "data": {
                "output_path": output_path,
                "pages": len(writer.pages),
                "files": len(input_paths),
            },
        }))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
