#!/usr/bin/env python3
"""Tool: search_youtube. Search YouTube and return video results as cards.

Args: {"query": "...", "max_results": <optional int, default 10>,
       "sort": <optional "relevance" | "newest" | "views", default "relevance">}

Fetches the YouTube search results page and parses its embedded `ytInitialData`
JSON, which contains a `videoRenderer` for every result. Each video carries
title, url, thumbnail, channel, views, duration and upload time so the web UI
can render a `.search-embed source-youtube` card.

Sorting is done client-side from the parsed fields rather than via YouTube's
`sp` sort token, which is unreliable and locale-dependent; the view count and
upload age are parsed directly and locale-safely.
"""
import sys
import os
import re
import json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cerisier_search import (http_get, clean_text, truncate, emit, fail, parse_args, get_num, UA_BROWSER)

_SEC_MIN = 60
_SEC_HR = 3600
_SEC_DAY = 86400
_SEC_WEEK = 604800
_SEC_MONTH = 2592000
_SEC_YEAR = 31536000

# English upload-age units (both the abbreviated "4y/12mo/3w" and the
# full-word "2 years" forms YouTube emits).
_UNITS_EN = {
    "s": _SEC_MIN, "sec": _SEC_MIN, "secs": _SEC_MIN, "second": _SEC_MIN, "seconds": _SEC_MIN,
    "m": _SEC_MIN, "min": _SEC_MIN, "mins": _SEC_MIN, "minute": _SEC_MIN, "minutes": _SEC_MIN,
    "h": _SEC_HR, "hr": _SEC_HR, "hrs": _SEC_HR, "hour": _SEC_HR, "hours": _SEC_HR,
    "d": _SEC_DAY, "day": _SEC_DAY, "days": _SEC_DAY,
    "w": _SEC_WEEK, "wk": _SEC_WEEK, "week": _SEC_WEEK, "weeks": _SEC_WEEK,
    "mo": _SEC_MONTH, "month": _SEC_MONTH, "months": _SEC_MONTH,
    "y": _SEC_YEAR, "yr": _SEC_YEAR, "yrs": _SEC_YEAR, "year": _SEC_YEAR, "years": _SEC_YEAR,
}
# French fallback (the proxy sometimes serves a non-English locale).
_UNITS_FR = {
    "an": _SEC_YEAR, "ans": _SEC_YEAR, "annee": _SEC_YEAR, "annees": _SEC_YEAR,
    "mois": _SEC_MONTH,
    "semaine": _SEC_WEEK, "semaines": _SEC_WEEK,
    "jour": _SEC_DAY, "jours": _SEC_DAY,
    "heure": _SEC_HR, "heures": _SEC_HR,
    "minute": _SEC_MIN, "minutes": _SEC_MIN,
    "seconde": _SEC_MIN, "secondes": _SEC_MIN,
}


def _runs_to_text(obj):
    """Extract text from a YouTube {runs:[{text:...}]} or {simpleText:...}."""
    if not isinstance(obj, dict):
        return ""
    if "simpleText" in obj:
        return clean_text(obj.get("simpleText", ""))
    runs = obj.get("runs", [])
    if isinstance(runs, list):
        return clean_text("".join(r.get("text", "") for r in runs if isinstance(r, dict)))
    return ""


def _channel(v):
    owner = v.get("ownerChannel") or v.get("longBylineText")
    if isinstance(owner, dict):
        if "channelRenderer" in owner:
            return _runs_to_text(owner["channelRenderer"].get("title", {}))
    return _runs_to_text(owner)


def _thumbnail(v):
    t = v.get("thumbnail", {})
    if not isinstance(t, dict):
        return ""
    items = t.get("thumbnails", [])
    if not isinstance(items, list) or not items:
        return ""
    last = items[-1] if isinstance(items[-1], dict) else {}
    url = re.sub(r"\?.*$", "", last.get("url", ""))
    return url


def _view_count(vc):
    """Parse a view-count string locale-safely (commas/spaces/suffix ignored)."""
    digits = re.sub(r"\D", "", vc or "")
    return int(digits) if digits else 0


def _age_seconds(text):
    """Seconds ago from a YouTube upload-age string, or None if unknown."""
    if not text:
        return None
    t = text.strip().lower()
    # French form: "il y a 4 ans", "il y a 3 mois".
    m = re.search(r"il y a\s+(\d+)\s+(\w+)", t)
    if m:
        return int(m.group(1)) * _UNITS_FR.get(m.group(2), 0) or None
    # English/numeric form: "4y ago", "12d ago", "3 months ago".
    m = re.search(r"(\d+)\s*([a-z]+)", t)
    if not m:
        return None
    unit = _UNITS_EN.get(m.group(2))
    return int(m.group(1)) * unit if unit else None


def _collect_video_renderers(node, found):
    """Walk the embedded JSON for every `videoRenderer` object."""
    if isinstance(node, dict):
        if "videoRenderer" in node and isinstance(node["videoRenderer"], dict):
            found.append(node["videoRenderer"])
        for v in node.values():
            _collect_video_renderers(v, found)
    elif isinstance(node, list):
        for v in node:
            _collect_video_renderers(v, found)


def _extract_initial_data(html):
    for pat in (r"var\s+ytInitialData\s*=\s*(\{.*?\});\s*window\.ytInitialData",
                r"window\.ytInitialData\s*=\s*(\{.*?\});\s*window\.ytInitialData",
                r"var\s+ytInitialData\s*=\s*(\{.*?\});"):
        m = re.search(pat, html, re.S)
        if m:
            try:
                return json.loads(m.group(1))
            except (ValueError, TypeError):
                pass
    return None


def _sort_results(results, sort):
    """Order client-side. Unparseable fields sink to the end (stable sort)."""
    if sort == "views":
        return sorted(results, key=lambda r: -r.get("_views", 0))
    if sort == "newest":
        return sorted(results, key=lambda r: (r.get("_age") is None, r.get("_age") or float("inf")))
    return results  # relevance: keep YouTube's returned order


def youtube_results(query, max_results, sort="relevance"):
    params = {"q": query, "search_query": query, "hl": "en", "gl": "US"}
    r = http_get("https://www.youtube.com/results", params=params,
                 headers={"User-Agent": UA_BROWSER, "Accept-Language": "en-US"})
    if r.status_code != 200:
        return None, f"youtube returned {r.status_code}"
    data = _extract_initial_data(r.text)
    if data is None:
        return None, "could not parse youtube initial data"
    renderers = []
    _collect_video_renderers(data, renderers)
    out = []
    for v in renderers:
        vid = clean_text(v.get("videoId", ""))
        if not vid:
            continue
        title = _runs_to_text(v.get("title", {})) or "(untitled)"
        views = _runs_to_text(v.get("viewCountText", {}))
        out.append({
            "id": vid,
            "title": truncate(title, 200),
            "url": f"https://www.youtube.com/watch?v={vid}",
            "thumbnail": _thumbnail(v) or f"https://i.ytimg.com/vi/{vid}/hq720.jpg",
            "channel": _channel(v),
            "views": views,
            "duration": _runs_to_text(v.get("lengthText", {})),
            "published": _runs_to_text(v.get("publishedTimeText", {})),
            "_views": _view_count(views),
            "_age": _age_seconds(_runs_to_text(v.get("publishedTimeText", {}))),
        })
    out = _sort_results(out, sort)
    out = out[:max_results]
    for r in out:
        r.pop("_views", None)
        r.pop("_age", None)
    if not out:
        return None, "no results"
    return out, None


def main():
    args = parse_args()
    query = args.get("query", "")
    if not isinstance(query, str) or not query.strip():
        fail("query must be a non-empty string")
        return
    query = query.strip()
    max_results = get_num(args, "max_results", 10, lo=1, hi=50)
    sort = (args.get("sort") or "relevance").lower()
    if sort not in ("relevance", "newest", "views"):
        sort = "relevance"
    try:
        res, err = youtube_results(query, max_results, sort)
    except Exception as e:
        res, err = None, f"youtube search error: {e}"
    if not res:
        fail(f"youtube search failed: {err}")
        return
    emit("youtube", query, res, {"sort": sort})


if __name__ == "__main__":
    main()
