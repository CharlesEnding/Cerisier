#!/usr/bin/env python3
"""Shared helpers for the Cerisier search tools.

Every search tool prints one JSON object on the form:

    {"ok": true, "data": {"type": "search", "source": "web", "query": "...",
                          "results": [...], "text": "..."}}

`source` selects the card style in the web UI (see .search-embed in style.css
and renderSearchEmbed in app.js). Each entry in `results` carries the fields
that source uses; the UI only reads what is present and degrades gracefully.
`text` is a compact plain-text digest of the same results, so the model that
called the tool can reason over them without re-reading raw HTML.

Nothing here talks to a specific service; it is just HTTP, HTML and JSON
plumbing shared across web / github / steam / youtube.
"""
import json
import os
import sys

UA_BROWSER = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")
UA_ACCEPT = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"


def _requests():
    try:
        import requests
        return requests
    except ImportError:
        raise RuntimeError("requests is not installed")


def http_get(url, params=None, headers=None, timeout=15, session=None):
    """GET with a browser-ish user agent; returns the requests Response."""
    req = _requests()
    h = {"User-Agent": UA_BROWSER, "Accept": UA_ACCEPT}
    if headers:
        h.update(headers)
    s = session or req.Session()
    return s.get(url, params=params, headers=h, timeout=timeout, allow_redirects=True)


def http_post(url, data=None, headers=None, timeout=15, session=None):
    req = _requests()
    h = {"User-Agent": UA_BROWSER, "Accept": UA_ACCEPT,
         "Content-Type": "application/x-www-form-urlencoded"}
    if headers:
        h.update(headers)
    s = session or req.Session()
    return s.post(url, data=data, headers=h, timeout=timeout, allow_redirects=True)


def make_soup(html):
    """BeautifulSoup with a resilient parser fallback."""
    from bs4 import BeautifulSoup
    try:
        import lxml  # noqa: F401
        parser = "lxml"
    except ImportError:
        parser = "html.parser"
    try:
        return BeautifulSoup(html, parser)
    except Exception:
        return BeautifulSoup(html, "html.parser")


def clean_text(s):
    """Collapse whitespace, drop control chars, trim."""
    if s is None:
        return ""
    s = str(s)
    s = s.replace("\xa0", " ").replace("\u202f", " ")
    parts = s.split()
    return " ".join(parts)


def truncate(s, n):
    """Truncate on a word boundary and append an ellipsis when cut."""
    s = clean_text(s)
    if len(s) <= n:
        return s
    cut = s[:n]
    # prefer to cut at the last space
    if " " in cut:
        cut = cut[:cut.rfind(" ")]
    return cut + "..."


def strip_html(s):
    """Remove any HTML tags from a string (snippets can contain markup)."""
    import re
    s = re.sub(r"<[^>]+>", "", s or "")
    s = s.replace("&amp;", "&").replace("&quot;", '"').replace("&#39;", "'")
    s = s.replace("&lt;", "<").replace("&gt;", ">").replace("&nbsp;", " ")
    return clean_text(s)


def digest(source, query, results):
    """Compact plain-text summary of results for the LLM."""
    lines = []
    if source == "web":
        for i, r in enumerate(results, 1):
            lines.append(f"{i}. {r.get('title','')}")
            if r.get("url"):
                lines.append(f"   {r['url']}")
            if r.get("snippet"):
                lines.append(f"   {r['snippet']}")
    elif source == "github":
        kind = results[0].get("type", "repo") if results else "repo"
        lines.append(f"GitHub {kind} results for '{query}':")
        for i, r in enumerate(results, 1):
            if kind == "repo":
                extra = f" ({r.get('stars',0)} stars)"
                lang = f" [{r.get('language')}]" if r.get("language") else ""
                lines.append(f"{i}. {r.get('name','')}{lang}{extra}")
                if r.get("url"):
                    lines.append(f"   {r['url']}")
                if r.get("description"):
                    lines.append(f"   {r['description']}")
            elif kind == "user":
                lines.append(f"{i}. {r.get('name','') or r.get('login','')} "
                             f"({r.get('login','')})")
                if r.get("url"):
                    lines.append(f"   {r['url']}")
            else:  # issue
                st = r.get("state", "")
                lines.append(f"{i}. #{r.get('number','')} {r.get('title','')} [{st}]")
                if r.get("repo"):
                    lines.append(f"   {r['repo']}")
                if r.get("url"):
                    lines.append(f"   {r['url']}")
    elif source == "steam":
        for i, r in enumerate(results, 1):
            price = r.get("price_text") or ""
            rev = r.get("review_text") or ""
            tail = " ".join(x for x in (price, rev) if x)
            lines.append(f"{i}. {r.get('name','')} ({r.get('appid','')})"
                         + (f" - {tail}" if tail else ""))
            if r.get("url"):
                lines.append(f"   {r['url']}")
    elif source == "youtube":
        for i, r in enumerate(results, 1):
            tail = " ".join(x for x in (r.get("duration",""), r.get("views",""),
                                        r.get("published","")) if x)
            lines.append(f"{i}. {r.get('title','')} [{r.get('channel','')}]"
                         + (f" - {tail}" if tail else ""))
            if r.get("url"):
                lines.append(f"   {r['url']}")
    return "\n".join(lines)


def emit(source, query, results, extra=None):
    """Build and print the standard search envelope, then exit 0."""
    data = {"type": "search", "source": source, "query": clean_text(query),
            "results": results, "text": digest(source, query, results)}
    if extra:
        data.update(extra)
    print(json.dumps({"ok": True, "data": data}, ensure_ascii=False))


def fail(msg):
    print(json.dumps({"ok": False, "error": msg}, ensure_ascii=False))


def parse_args():
    try:
        return json.loads(sys.argv[1])
    except (IndexError, json.JSONDecodeError):
        fail("invalid arguments")
        sys.exit(0)


def get_num(obj, key, default=0, lo=None, hi=None):
    """Coerce an optional numeric argument into a clamped int."""
    try:
        v = int(obj.get(key, default))
    except (TypeError, ValueError):
        v = default
    if lo is not None:
        v = max(lo, v)
    if hi is not None:
        v = min(hi, v)
    return v
