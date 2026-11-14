#!/usr/bin/env python3
"""Tool: pdf_split. Split a PDF into one file per page.

Args: {"input_path": "...", "output_dir": "...", "prefix": "<optional, default 'page'>"}
Writes `prefix-001.pdf`, `prefix-002.pdf`, ... (one page each) into `output_dir`
(creating it if needed, no sandboxing). Returns the directory, the page count,
and the list of written file paths.
"""
import json
import os
import sys
import warnings

warnings.filterwarnings("ignore", category=Warning)


def main():
    try:
        args = json.loads(sys.argv[1])
        input_path = args["input_path"]
        output_dir = args["output_dir"]
        prefix = str(args.get("prefix", "page"))
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
        os.makedirs(output_dir, exist_ok=True)
        written = []
        for idx, page in enumerate(reader.pages):
            out = pypdf.PdfWriter()
            out.add_page(page)
            name = f"{prefix}-{idx + 1:03d}.pdf"
            path = os.path.join(output_dir, name)
            with open(path, "wb") as f:
                out.write(f)
            written.append(path)
        print(json.dumps({
            "ok": True,
            "data": {
                "output_dir": output_dir,
                "pages": len(written),
                "files": written,
            },
        }))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
