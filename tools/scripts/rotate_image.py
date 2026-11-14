#!/usr/bin/env python3
"""Tool: rotate_image. Rotate an image by a clockwise angle in degrees.

Args: {"input_path": "...", "output_path": "...", "angle": <number>}
The angle is clockwise (e.g. 90 turns a portrait into a landscape). The output
canvas is expanded so nothing is cropped. The output format is inferred from the
output file's extension. No sandboxing.
"""
import json
import os
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
        angle = float(args.get("angle", 0))
    except (IndexError, KeyError, json.JSONDecodeError, ValueError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return

    try:
        img = Image.open(input_path)
        # PIL rotates counter-clockwise, so negate for a clockwise angle.
        img = img.rotate(-angle, expand=True)
        img.save(output_path)
        print(json.dumps({
            "ok": True,
            "data": {
                "output_path": output_path,
                "width": img.width,
                "height": img.height,
                "angle": angle,
            },
        }))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
