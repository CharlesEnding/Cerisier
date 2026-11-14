#!/usr/bin/env python3
"""Tool: read_webpage. Fetch a web page and extract its readable content.

Args: {"url": "...",
       "output_path": <optional>,
       "format": <"text" | "markdown" | "html" | "raw", default "markdown">,
       "selector": <optional CSS selector to scope extraction>,
       "max_chars": <optional int>,
       "strip_boilerplate": <optional bool, default true>,
       "timeout": <optional seconds, default 20>}

Fetches `url` over HTTP(S), follows redirects, parses the HTML and returns the
page title plus extracted content in the requested `format` (default markdown). When no `selector`
is given and `strip_boilerplate` is true, common noise elements (nav, footer,
aside, header) are removed so the result is closer to a reader view. If
`output_path` is given the content is written to that file and only metadata
(path, counts) is returned, not the text itself. No sandboxing.
"""
import json
import os
import re
import sys
import warnings

warnings.simplefilter("ignore")

MAX_RETURN_BYTES = 1024 * 1024

# Always removed: things that are never readable prose.
ALWAYS_DROP = ["script", "style", "noscript", "template", "svg", "iframe"]
# Dropped only when scoping to the whole page (reader-view heuristic).
BOILERPLATE = ["nav", "footer", "aside", "header", "form"]


def _strip_tags(text):
    """Fallback when BeautifulSoup is unavailable: crude tag stripping."""
    text = re.sub(r"<(script|style|noscript|template|svg)[^>]*>.*?</\1>",
                  "", text, flags=re.IGNORECASE | re.DOTALL)
    text = re.sub(r"<[^>]+>", " ", text)
    text = re.sub(r"&nbsp;", " ", text)
    text = re.sub(r"&[a-z]+;", " ", text)
    return _collapse(text)


def _collapse(text):
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def _make_soup(body):
    from bs4 import BeautifulSoup
    try:
        import lxml  # noqa: F401
        parser = "lxml"
    except ImportError:
        parser = "html.parser"
    try:
        return BeautifulSoup(body, parser)
    except Exception:
        return BeautifulSoup(body, "html.parser")


def main():
    try:
        args = json.loads(sys.argv[1])
        url = args["url"]
    except (IndexError, KeyError, json.JSONDecodeError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return

    if not isinstance(url, str) or not url:
        print(json.dumps({"ok": False, "error": "url must be a non-empty string"}))
        return

    output_path = args.get("output_path")
    fmt = (args.get("format") or "markdown").lower()
    if fmt not in ("text", "markdown", "html", "raw"):
        print(json.dumps({"ok": False, "error": "format must be text|markdown|html|raw"}))
        return
    selector = args.get("selector")
    max_chars = args.get("max_chars")
    strip_boilerplate = bool(args.get("strip_boilerplate", True))
    try:
        timeout = float(args.get("timeout", 20))
    except (TypeError, ValueError):
        timeout = 20.0

    try:
        import requests
    except ImportError:
        print(json.dumps({"ok": False, "error": "requests is not installed"}))
        return

    headers = {
        "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,text/plain,*/*",
    }
    try:
        resp = requests.get(url, headers=headers, timeout=timeout, allow_redirects=True)
    except Exception as e:
        print(json.dumps({"ok": False, "error": f"fetch failed: {e}"}))
        return

    status = resp.status_code
    ctype = resp.headers.get("Content-Type", "")
    try:
        resp.encoding = resp.encoding or resp.apparent_encoding
    except Exception:
        pass
    body = resp.text or ""

    title = ""
    content = ""
    selector_found = True
    is_html = "html" in ctype.lower() or "xml" in ctype.lower()

    if is_html:
        try:
            soup = _make_soup(body)
        except Exception:
            soup = None

        if soup is not None:
            try:
                if soup.title and soup.title.string:
                    title = soup.title.string.strip()
            except Exception:
                title = ""

            # Remove elements that are never readable prose.
            for tag in soup(ALWAYS_DROP):
                tag.decompose()
            # Reader-view heuristic: drop common chrome when not scoped.
            if strip_boilerplate and not selector:
                for tag in soup(BOILERPLATE):
                    tag.decompose()

            target = soup
            if selector:
                try:
                    found = soup.select_one(selector)
                except Exception as e:
                    print(json.dumps({"ok": False, "error": f"invalid selector: {e}"}))
                    return
                if found is None:
                    selector_found = False
                    target = None
                else:
                    target = found

            if fmt == "raw":
                content = body
            elif fmt == "html":
                content = str(target) if target is not None else ""
            elif fmt == "markdown":
                if target is not None:
                    try:
                        import html2text
                        content = _collapse(html2text.convert(str(target)))
                    except Exception:
                        content = _collapse(target.get_text("\n"))
                else:
                    content = ""
            else:  # text
                content = _collapse(target.get_text("\n")) if target is not None else ""
        else:
            content = _strip_tags(body)
    else:
        # text/plain, json, etc. -> return the body as-is.
        content = body

    truncated = False
    if max_chars is not None:
        try:
            mc = int(max_chars)
            if mc > 0 and len(content) > mc:
                content = content[:mc]
                truncated = True
        except (TypeError, ValueError):
            pass

    # If returning the text inline, cap it like the other read tools.
    if not output_path and len(content) > MAX_RETURN_BYTES:
        content = content[:MAX_RETURN_BYTES]
        truncated = True

    data = {
        "title": title,
        "status_code": status,
        "content_type": ctype,
        "characters": len(content),
        "truncated": truncated,
        "content": "" if output_path else content,
    }
    if selector is not None:
        data["selector_found"] = selector_found

    if output_path:
        try:
            parent = os.path.dirname(output_path)
            if parent:
                os.makedirs(parent, exist_ok=True)
            with open(output_path, "w", encoding="utf-8") as f:
                f.write(content)
            data["output_path"] = output_path
        except Exception as e:
            print(json.dumps({"ok": False, "error": str(e)}))
            return

    print(json.dumps({"ok": True, "data": data}))


if __name__ == "__main__":
    main()
