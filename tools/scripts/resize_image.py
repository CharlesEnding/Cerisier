#!/usr/bin/env python3
"""Tool: resize_image. Resize an image.

Args: {"input_path": "...", "output_path": "...", "width": <int?>,
       "height": <int?>, "keep_aspect": <bool, default true>}
- Both width and height given with keep_aspect=true: scale so the image fits
  *inside* that box (aspect ratio preserved, no distortion).
- Both given with keep_aspect=false: force exactly that size (may distort).
- Only one of width/height given: the other is scaled to keep the aspect ratio,
  and the given dimension is honored exactly.
- Neither given: error. Output format inferred from the output extension.
No sandboxing.
"""
import json
import sys

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    print(json.dumps({"ok": False, "error": "Pillow (PIL) is not installed"}))
    sys.exit(0)


def main():
    try:
        args = json.loads(sys.argv[1])
        input_path = args["input_path"]
        output_path = args["output_path"]
        width = args.get("width")
        height = args.get("height")
        keep_aspect = bool(args.get("keep_aspect", True))
        if width is not None:
            width = int(width)
        if height is not None:
            height = int(height)
    except (IndexError, KeyError, json.JSONDecodeError, ValueError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return

    both = width is not None and height is not None
    if width is None and height is None:
        print(json.dumps({"ok": False, "error": "pass at least one of width/height"}))
        return

    try:
        img = Image.open(input_path)
        w, h = img.size

        if both and keep_aspect:
            # fit inside the box
            ratio = min(width / w, height / h)
            size = (max(1, round(w * ratio)), max(1, round(h * ratio)))
        elif width is None:
            # only height: honor it, scale width to keep aspect ratio
            size = (max(1, round(w * height / h)), max(1, height))
        elif height is None:
            # only width: honor it, scale height to keep aspect ratio
            size = (max(1, width), max(1, round(h * width / w)))
        else:
            # both given, keep_aspect false: force exact size (may distort)
            size = (max(1, width), max(1, height))

        img = img.resize(size, Image.LANCZOS)
        img.save(output_path)
        print(json.dumps({
            "ok": True,
            "data": {
                "output_path": output_path,
                "width": img.width,
                "height": img.height,
            },
        }))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
