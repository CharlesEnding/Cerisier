#!/usr/bin/env python3
"""Tool: pdf_form. Generate a fillable PDF form from a field list.

Args: {"output_path": "...", "fields": [...], "page_width": <int, default 595>,
       "page_height": <int, default 842>, "title": "<optional string>"}
Coordinates use PDF origin (bottom-left), in points (72 pt = 1 inch). Each
field is an object:
  {"type": "text"|"checkbox"|"choice"|"listbox"|"label",
   "name": "<str>",           # widget name (ignored by 'label')
   "x": <int>, "y": <int>,    # bottom-left of the field
   "width": <int>, "height": <int>,   # default text/choice/listbox 120x18
   "value": "<str>",          # initial value / for checkbox 'true'
   "options": [["label","export"], ...],  # choice/listbox
   "label": "<str>"}          # static text drawn next to/over the field (all types)
`label` (the field's own key) draws human text; a field of type "label" draws
text only and creates no widget. Writes the PDF to `output_path` (no
sandboxing); returns the path and the widget count. Radio groups are not
supported by this build; use choice or listbox instead.
"""
import json
import os
import sys


def main():
    try:
        args = json.loads(sys.argv[1])
        output_path = args["output_path"]
        fields = args.get("fields") or []
        page_width = float(args.get("page_width", 595))
        page_height = float(args.get("page_height", 842))
        title = args.get("title")
    except (IndexError, KeyError, json.JSONDecodeError, ValueError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return

    if not isinstance(fields, list):
        print(json.dumps({"ok": False, "error": "fields must be a list"}))
        return

    try:
        from reportlab.pdfgen import canvas
        from reportlab.lib.colors import black
    except ImportError:
        print(json.dumps({"ok": False, "error": "reportlab is not installed"}))
        return

    try:
        parent = os.path.dirname(output_path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        c = canvas.Canvas(output_path, pagesize=(page_width, page_height))
        ac = c.acroForm
        widgets = 0
        if title:
            c.setFont("Helvetica-Bold", 18)
            c.drawString(50, page_height - 50, str(title))
            c.setFont("Helvetica", 10)
        for i, f in enumerate(fields):
            if not isinstance(f, dict):
                print(json.dumps({"ok": False, "error": f"field {i} is not an object"}))
                return
            ftype = str(f.get("type", "")).lower()
            name = f.get("name") or f"field{i}"
            x = float(f.get("x", 50))
            y = float(f.get("y", 50))
            width = float(f.get("width", 120))
            height = float(f.get("height", 18))
            value = f.get("value")
            options = f.get("options") or []
            try:
                if ftype == "label":
                    c.setFont("Helvetica", 10)
                    c.drawString(x, y, str(f.get("label", value or "")))
                    continue
                # Optional static caption drawn to the left of the widget.
                if f.get("label"):
                    c.setFont("Helvetica", 10)
                    c.drawString(max(10, x - 40), y + height * 0.4, str(f["label"]))
                if ftype == "text":
                    ac.textfield(
                        name=name, x=x, y=y, width=width, height=height,
                        value=value or "", borderColor=black, borderWidth=0.5,
                    )
                elif ftype == "checkbox":
                    size = float(f.get("size", 12))
                    ac.checkbox(
                        name=name, x=x, y=y, size=size,
                        checked=bool(value), borderColor=black, borderWidth=0.5,
                    )
                elif ftype == "choice":
                    ac.choice(
                        name=name, x=x, y=y, width=width, height=height,
                        value=(value if value is not None else (options[0][1] if options else "")),
                        options=options, borderColor=black, borderWidth=0.5,
                    )
                elif ftype == "listbox":
                    ac.listbox(
                        name=name, x=x, y=y, width=width, height=max(height, 60),
                        value=(value if value is not None else (options[0][1] if options else "")),
                        options=options, borderColor=black, borderWidth=0.5,
                    )
                elif ftype == "radio":
                    print(json.dumps({
                        "ok": False,
                        "error": "radio groups are not supported by this build; use choice or listbox",
                    }))
                    return
                else:
                    print(json.dumps({
                        "ok": False,
                        "error": f"unknown field type {ftype!r} (text/checkbox/choice/listbox/label)",
                    }))
                    return
                widgets += 1
            except Exception as fe:
                print(json.dumps({"ok": False, "error": f"field {i} ({name}) failed: {fe}"}))
                return
        c.showPage()
        c.save()
        print(json.dumps({
            "ok": True,
            "data": {
                "output_path": output_path,
                "widgets": widgets,
            },
        }))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
