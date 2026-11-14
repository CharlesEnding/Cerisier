#!/usr/bin/env python3
"""Tool: convert_image. Convert an image between formats (PNG, JPEG, WEBP, BMP,
TIFF, GIF, ...).

Args: {"input_path": "...", "output_path": "...", "format": "<optional>",
       "quality": <int, 1-100, default 95>}
If `format` is omitted the target format is inferred from the output file's
extension. `quality` only affects lossy formats (JPEG, WEBP); it is ignored for
others. No sandboxing.
"""
import json
import os
import sys

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    print(json.dumps({"ok": False, "error": "Pillow (PIL) is not installed"}))
    sys.exit(0)

LOSSY = {"JPEG", "WEBP"}


def main():
    try:
        args = json.loads(sys.argv[1])
        input_path = args["input_path"]
        output_path = args["output_path"]
        fmt = args.get("format")
        quality = int(args.get("quality", 95))
    except (IndexError, KeyError, json.JSONDecodeError, ValueError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return

    try:
        img = Image.open(input_path)
        if not fmt:
            ext = os.path.splitext(output_path)[1].lower()
            fmt = {
                ".png": "PNG", ".jpg": "JPEG", ".jpeg": "JPEG",
                ".webp": "WEBP", ".bmp": "BMP", ".tif": "TIFF",
                ".tiff": "TIFF", ".gif": "GIF",
            }.get(ext)
        if not fmt:
            print(json.dumps({
                "ok": False,
                "error": "could not infer target format; pass a 'format' "
                         "or give the output a known extension",
            }))
            return
        fmt = fmt.upper()

        # JPEG cannot store transparency; flatten onto a white background.
        save_kwargs = {}
        if fmt in LOSSY:
            save_kwargs["quality"] = max(1, min(100, quality))
        if fmt == "JPEG" and img.mode in ("RGBA", "LA", "P"):
            img = img.convert("RGB")

        img.save(output_path, fmt, **save_kwargs)
        print(json.dumps({
            "ok": True,
            "data": {
                "output_path": output_path,
                "format": fmt,
                "width": img.width,
                "height": img.height,
            },
        }))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
