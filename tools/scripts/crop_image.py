#!/usr/bin/env python3
"""Tool: crop_image. Crop a rectangular region out of an image.

Args: {"input_path": "...", "output_path": "...", "x": <int>, "y": <int>,
       "width": <int>, "height": <int>}
x,y is the top-left corner of the crop box (in pixels, origin at the image's
top-left). The crop is clamped to the image bounds; values that fall outside are
ignored rather than erroring. Output format is inferred from the output
extension. No sandboxing.
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
        x = int(args["x"])
        y = int(args["y"])
        width = int(args["width"])
        height = int(args["height"])
    except (IndexError, KeyError, json.JSONDecodeError, ValueError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return

    try:
        img = Image.open(input_path)
        w, h = img.size
        left = max(0, min(x, w))
        top = max(0, min(y, h))
        right = min(w, left + width)
        bottom = min(h, top + height)
        if right <= left or bottom <= top:
            print(json.dumps({
                "ok": False,
                "error": "crop box is empty after clamping to image bounds",
            }))
            return
        img = img.crop((left, top, right, bottom))
        img.save(output_path)
        print(json.dumps({
            "ok": True,
            "data": {
                "output_path": output_path,
                "width": img.width,
                "height": img.height,
                "box": [left, top, right, bottom],
            },
        }))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
