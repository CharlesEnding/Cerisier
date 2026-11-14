#!/usr/bin/env python3
"""Tool: search_web. Search the web and return structured results as embed cards.

Args: {"query": "...", "max_results": <optional int, default 10>,
       "engine": <optional "bing" | "duckduckgo", default "bing">}

Uses Bing (HTML, reliable) as the primary engine and DuckDuckGo's HTML
endpoint as a fallback. Each result carries title, url and snippet so the
web UI can render a `.search-embed source-web` card.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cerisier_search import (http_get, http_post, make_soup, clean_text, truncate,
                             strip_html, emit, fail, parse_args, get_num, UA_BROWSER)

import re
import base64
import urllib.parse


def decode_bing_url(href):
    """Bing wraps real links in a /ck/a redirect that encodes the target in
    the `u=` parameter (a1/a2 prefix + base64url). Decode it back."""
    m = re.search(r"[&?]u=([^&]+)", href)
    if not m:
        return None
    v = urllib.parse.unquote(m.group(1))
    if v[:2] in ("a1", "a2"):
        v = v[2:]
    # base64url: '-' -> '+', '_' -> '/'
    v = v.replace("-", "+").replace("_", "/")
    v = v.rstrip("=")
    v = v + "=" * ((4 - len(v) % 4) % 4)
    pad = "=" * ((4 - len(v) % 4) % 4)
    try:
        return base64.b64decode(v + pad).decode("utf-8", "ignore")
    except Exception:
        return None


def bing_results(query, max_results):
    """Parse Bing's HTML SERP (li.b_algo) into title/url/snippet cards."""
    r = http_get("https://www.bing.com/search",
                 params={"q": query, "count": str(max(max_results, 10))},
                 headers={"User-Agent": UA_BROWSER})
    if r.status_code != 200:
        return None, f"bing returned {r.status_code}"
    soup = make_soup(r.text)
    out = []
    for d in soup.select("li.b_algo"):
        h2 = d.find("h2")
        a = h2.find("a") if h2 else d.find("a")
        if not a:
            continue
        href = a.get("href", "")
        real = decode_bing_url(href) or href
        if not real or real.startswith("javascript:"):
            continue
        title = clean_text(a.get_text(" ", strip=True)) or "(untitled)"
        sn = d.find("div", class_="b_caption")
        if not sn:
            p = d.find("p")
            sn = p if p else d
        snippet = truncate(strip_html(sn.get_text(" ", strip=True)), 360) if sn else ""
        out.append({"title": title, "url": real, "snippet": snippet})
        if len(out) >= max_results:
            break
    if not out:
        return None, "no results parsed from bing"
    return out, None


def ddg_results(query, max_results):
    """Parse DuckDuckGo's HTML endpoint (div.result) as a fallback."""
    out = []
    # DuckDuckGo serves an anti-bot challenge on GET; POST is the reliable path.
    r = http_post("https://html.duckduckgo.com/html/",
                  data={"q": query, "ie": "UTF-8"},
                  headers={"User-Agent": UA_BROWSER,
                           "Referer": "https://duckduckgo.com/"})
    if r.status_code != 200 or "result__a" not in r.text:
        return None, f"duckduckgo returned {r.status_code}"
    soup = make_soup(r.text)
    for d in soup.select("div.result"):
        a = d.find("a", class_="result__a")
        if not a:
            continue
        href = a.get("href", "")
        # DDG html href is the real target (not wrapped), skip sponsored links.
        if "y.js" in href or "ad_domain" in href:
            continue
        title = clean_text(a.get_text(" ", strip=True)) or "(untitled)"
        sn = d.find(class_="result__snippet")
        snippet = truncate(strip_html(sn.get_text(" ", strip=True)), 360) if sn else ""
        out.append({"title": title, "url": href, "snippet": snippet})
        if len(out) >= max_results:
            break
    if not out:
        return None, "no results parsed from duckduckgo"
    return out, None


def main():
    args = parse_args()
    query = args.get("query", "")
    if not isinstance(query, str) or not query.strip():
        fail("query must be a non-empty string")
        return
    query = query.strip()
    max_results = get_num(args, "max_results", 10, lo=1, hi=50)
    engine = (args.get("engine") or "bing").lower()

    # engine == "bing" or "auto": try bing then fall back to duckduckgo.
    # engine == "duckduckgo": duckduckgo first, bing as fallback.
    if engine == "duckduckgo":
        order = ["duckduckgo", "bing"]
    else:
        engine = "bing"
        order = ["bing", "duckduckgo"]

    parsers = {"bing": bing_results, "duckduckgo": ddg_results}
    results = None
    error = None
    for name in order:
        try:
            res, err = parsers[name](query, max_results)
        except Exception as e:
            res, err = None, f"{name} error: {e}"
        if res:
            results = res
            engine = name
            break
        error = err

    if not results:
        fail(f"web search failed: {error}")
        return

    emit("web", query, results, {"engine": engine})


if __name__ == "__main__":
    main()
