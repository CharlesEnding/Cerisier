#!/usr/bin/env python3
"""Tool: screenshot. Capture a screenshot on the local X11 desktop.

Args: {"mode": "full"|"window"|"list" (default "full"),
       "window": "<title substring or window id, for mode window>",
       "output_path": "<file, optional>", "format": "png|jpg|webp",
       "quality": <1-100 for jpg/webp>}

Backend auto-detection: uses ImageMagick `import` when present (handles both
full-screen via `-window root` and a single window via `-window <id>`, with the
output format inferred from the file extension), and falls back to ffmpeg's
x11grab. `xdotool` resolves a window title to an id; `wmctrl -l` enumerates
windows for `mode: "list"`. No sandboxing.
"""
import json
import os
import re
import subprocess
import sys
import time
import shutil

VALID_FMT = {"png", "jpg", "jpeg", "webp"}


def run(cmd, timeout=8):
    """Run a command list, returning (rc, stdout, stderr); rc=127 if missing."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout or "", p.stderr or ""
    except FileNotFoundError:
        return 127, "", "command not found"
    except subprocess.TimeoutExpired:
        return 124, "", "timed out"


def image_size(path):
    """Read width/height from a PNG or JPEG header without Pillow."""
    try:
        with open(path, "rb") as f:
            b = f.read(512)
    except OSError:
        return None, None
    if b[:8] == b"\x89PNG\r\n\x1a\n" and len(b) >= 24:
        w = int.from_bytes(b[16:20], "big")
        h = int.from_bytes(b[20:24], "big")
        return w, h
    if b[:2] == b"\xff\xd8":
        i = 2
        while i + 9 < len(b):
            if b[i] != 0xFF:
                i += 1
                continue
            m = b[i + 1]
            if m in (0xD0, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9):
                i += 2
                continue
            if 0xC0 <= m <= 0xC3 or 0xC5 <= m <= 0xCF:
                h = int.from_bytes(b[i + 5:i + 7], "big")
                w = int.from_bytes(b[i + 7:i + 9], "big")
                return w, h
            ln = int.from_bytes(b[i + 2:i + 4], "big")
            i += 2 + ln
    return None, None


def list_windows():
    """Return [{id, title}] for open windows, via wmctrl then xdotool."""
    rc, out, _ = run(["wmctrl", "-l"], timeout=6)
    if rc == 0 and out.strip():
        result = []
        for line in out.splitlines():
            parts = line.split(None, 3)
            if len(parts) < 4:
                continue
            result.append({"id": parts[0], "title": parts[3].strip()})
        return result
    # Fallback: enumerate via xdotool and ask for each name.
    rc, out, _ = run(["xdotool", "search", "--name", ""], timeout=6)
    ids = [x.strip() for x in out.splitlines() if x.strip()][:60]
    result = []
    for wid in ids:
        rc2, name, _ = run(["xdotool", "getwindowname", wid], timeout=3)
        result.append({"id": wid, "title": name.strip() if rc2 == 0 else ""})
    return result


def resolve_window(window):
    """Resolve a window arg to a numeric id string, or return an error dict."""
    w = (window or "").strip()
    if not w:
        return None, {"error": "window is required for mode 'window'"}
    if re.fullmatch(r"0x[0-9a-fA-F]+", w):
        return str(int(w, 16)), None
    if re.fullmatch(r"\d+", w):
        return w, None
    if not shutil.which("xdotool"):
        return None, {"error": "xdotool not available to search windows by title"}
    rc, out, err = run(["xdotool", "search", "--name", w], timeout=5)
    ids = [x.strip() for x in out.splitlines() if x.strip()]
    if not ids:
        avail = list_windows()
        return None, {
            "error": f"no window matches {w!r}",
            "hint": "list the open windows with mode='list' to find the right title",
            "windows": avail[:30],
        }
    return ids[0], None


def window_geometry(wid):
    """Absolute (x, y, w, h) of a window via xwininfo, else xdotool."""
    rc, out, _ = run(["xwininfo", "-id", wid], timeout=5)
    if rc == 0:
        ax = re.search(r"Absolute upper-left X:\s*(\d+)", out)
        ay = re.search(r"Absolute upper-left Y:\s*(\d+)", out)
        wd = re.search(r"Width:\s*(\d+)", out)
        ht = re.search(r"Height:\s*(\d+)", out)
        if all((ax, ay, wd, ht)):
            return int(ax.group(1)), int(ay.group(1)), int(wd.group(1)), int(ht.group(1))
    rc, out, _ = run(["xdotool", "getwindowgeometry", wid], timeout=5)
    if rc == 0:
        pos = re.search(r"Position:\s*(-?\d+),(-?\d+)", out)
        geo = re.search(r"Geometry:\s*(\d+)x(\d+)", out)
        if pos and geo:
            return int(pos.group(1)), int(pos.group(2)), int(geo.group(1)), int(geo.group(2))
    return None


def ordered_backends():
    has_import = bool(shutil.which("import"))
    has_ffmpeg = bool(shutil.which("ffmpeg"))
    if has_import and has_ffmpeg:
        return ["import", "ffmpeg"]
    if has_import:
        return ["import"]
    if has_ffmpeg:
        return ["ffmpeg"]
    return ["import", "ffmpeg"]  # try anyway; PATH may differ


def _import_cmd(target, filename, fmt, quality):
    cmd = ["import"]
    if fmt in ("jpg", "jpeg", "webp") and quality:
        cmd += ["-quality", str(max(1, min(100, quality)))]
    cmd += ["-window", target, filename]
    return cmd


def _ffmpeg_full(filename):
    return ["ffmpeg", "-y", "-f", "x11grab", "-i", ":0.0", "-vframes", "1", filename]


def _ffmpeg_region(filename, geom):
    x, y, w, h = geom
    return ["ffmpeg", "-y", "-f", "x11grab", "-s", f"{w}x{h}", "-i", f":0.0+{x}+{y}",
            "-vframes", "1", filename]


def capture_full(filename, fmt, quality):
    for backend in ordered_backends():
        if backend == "import":
            cmd = _import_cmd("root", filename, fmt, quality)
        else:
            cmd = _ffmpeg_full(filename)
        rc, out, err = run(cmd, timeout=10)
        if rc == 0 and os.path.exists(filename) and os.path.getsize(filename) > 0:
            return backend
    raise RuntimeError("could not capture the full screen (import/ffmpeg failed)")


def capture_window(wid, filename, fmt, quality):
    last = ""
    for backend in ordered_backends():
        if backend == "import":
            cmd = _import_cmd(wid, filename, fmt, quality)
        else:
            geom = window_geometry(wid)
            if not geom:
                last = "window geometry unavailable for ffmpeg fallback"
                continue
            cmd = _ffmpeg_region(filename, geom)
        rc, out, err = run(cmd, timeout=10)
        if rc == 0 and os.path.exists(filename) and os.path.getsize(filename) > 0:
            return backend
        last = err[:300]
    raise RuntimeError(f"could not capture window {wid}: {last}")


def resolve_output(args):
    fmt = (args.get("format") or "").strip().lower()
    fmt = fmt if fmt in VALID_FMT else None
    filename_fmt = None
    out = args.get("output_path")
    if not out:
        ext = fmt or "png"
        ts = time.strftime("%Y%m%d-%H%M%S")
        out = os.path.join(os.getcwd(), f"screenshot_{ts}.{ext}")
        filename_fmt = ext
    else:
        base, ext = os.path.splitext(out)
        ext = ext.lower().lstrip(".")
        if fmt is None:
            fmt = ext if ext in VALID_FMT else "png"
        filename_fmt = "jpg" if fmt == "jpeg" else fmt
        if ext != filename_fmt:
            out = base + "." + filename_fmt
    d = os.path.dirname(out)
    if d:
        os.makedirs(d, exist_ok=True)
    return out, filename_fmt


def main():
    try:
        args = json.loads(sys.argv[1])
    except (IndexError, json.JSONDecodeError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return

    try:
        mode = (args.get("mode") or "full").strip().lower()
        if mode not in ("full", "window", "list"):
            print(json.dumps({"ok": False, "error": "mode must be full|window|list"}))
            return

        if not os.environ.get("DISPLAY"):
            print(json.dumps({"ok": False, "error": "no X11 DISPLAY is set; screenshot requires a graphical session"}))
            return

        if mode == "list":
            windows = list_windows()
            print(json.dumps({"ok": True, "data": {"mode": "list", "count": len(windows), "windows": windows}}))
            return

        out, fmt = resolve_output(args)
        quality = int(args.get("quality", 95))

        if mode == "full":
            backend = capture_full(out, fmt, quality)
            wid = None
        else:
            wid, err = resolve_window(args.get("window"))
            if err:
                print(json.dumps({"ok": False, "error": err["error"], "data": {k: v for k, v in err.items() if k != "error"}}))
                return
            backend = capture_window(wid, out, fmt, quality)

        w, h = image_size(out)
        data = {"mode": mode, "output_path": out, "format": fmt, "width": w, "height": h, "backend": backend}
        if wid is not None:
            data["window"] = wid
        print(json.dumps({"ok": True, "data": data}))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
