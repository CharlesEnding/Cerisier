#!/usr/bin/env python3
"""Tool: pdf_extract_images. Extract embedded images from a PDF into files.

Args: {"input_path": "...", "output_dir": "...", "prefix": "<optional, default 'img'>"}
Walks every page and writes each embedded image as `prefix-<page>-<n>.png`
into `output_dir` (created if needed, no sandboxing). Images that cannot be
decoded are skipped. Returns the directory, the number written, and their paths.
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
        prefix = str(args.get("prefix", "img"))
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
        for pno, page in enumerate(reader.pages):
            try:
                images = list(page.images)
            except Exception:
                continue
            for i, obj in enumerate(images):
                try:
                    pil = obj.image
                except Exception:
                    continue  # skip images this build cannot decode
                if pil is None:
                    continue
                name = f"{prefix}-{pno + 1:03d}-{i + 1:03d}.png"
                path = os.path.join(output_dir, name)
                try:
                    pil.save(path)
                    written.append(path)
                except Exception:
                    continue
        print(json.dumps({
            "ok": True,
            "data": {
                "output_dir": output_dir,
                "count": len(written),
                "files": written,
            },
        }))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
