#!/usr/bin/env python3
"""Tool: search_steam. Search the Steam store for games/apps.

Args: {"query": "...", "max_results": <optional int, default 10>}

Uses the Steam store search results page (no API key required). Each result
carries the fields the `.search-embed source-steam` card needs: appid, name,
url, capsule image, price (text + final cents), discount, review summary, and
platform icons.
"""
import sys
import os
import re

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cerisier_search import (http_get, make_soup, clean_text, truncate, strip_html,
                             emit, fail, parse_args, get_num, UA_BROWSER)

BASE_URL = "https://store.steampowered.com/app/"


def _platforms(a):
    icons = []
    for s in a.find_all("span", class_="platform_img"):
        cls = s.get("class", [])
        for c in cls:
            if c.startswith("platform_") and c != "platform_img":
                icons.append(c)
    return icons


def _price(a):
    """Return (text, final_cents, discount_pct). Price is cents in data-price-final."""
    pd = a.find("div", class_="search_price_discount_combined")
    final = None
    if pd and pd.get("data-price-final") is not None:
        try:
            final = int(pd.get("data-price-final"))
        except (ValueError, TypeError):
            final = None
    text = ""
    disc = ""
    if pd:
        # Discount badge: "N% off"
        db = pd.find("div", class_="search_discount")
        if db:
            disc = clean_text(db.get_text(" ", strip=True))
        # Price block ("text" is the human price)
        pb = pd.find("div", class_="search_price")
        if pb:
            text = clean_text(pb.get_text(" ", strip=True))
    if not text and final is not None:
        if final == 0:
            text = "Free"
        else:
            text = f"{final / 100:.2f}"
    return text, final, disc


def _review(a):
    span = a.find("span", class_="search_review_summary")
    if not span:
        return ""
    tip = span.get("data-tooltip-html", "") or ""
    # Tooltip HTML like: "Very Positive<br>91% of the 165,499 user reviews f..."
    text = re.sub(r"<br>", " ", tip)
    text = strip_html(text)
    return text[:140]


def steam_results(query, max_results):
    out = []
    # Steam paginates with a `page` (1-based). Fetch enough pages to fill the
    # requested count (search returns up to 25 per page).
    per_page = 25
    pages_needed = max(1, (max_results + per_page - 1) // per_page)
    for page in range(1, pages_needed + 1):
        r = http_get("https://store.steampowered.com/search/results",
                     params={"term": query, "count": str(per_page), "start": str((page - 1) * per_page)},
                     headers={"User-Agent": UA_BROWSER,
                              "Referer": "https://store.steampowered.com/"})
        if r.status_code != 200:
            if page == 1:
                return None, f"steam returned {r.status_code}"
            break
        soup = make_soup(r.text)
        rows = soup.select("a.search_result_row")
        for a in rows:
            if len(out) >= max_results:
                return out, None
            appid = clean_text(a.get("data-ds-appid", ""))
            title_el = a.find("span", class_="title")
            name = clean_text(title_el.get_text(" ", strip=True)) if title_el else ""
            if not name:
                continue
            url = clean_text(a.get("href", ""))
            if not url and appid:
                url = BASE_URL + appid
            img = a.find("img")
            capsule = clean_text(img.get("src", "")) if img else ""
            ptext, pfinal, pdisc = _price(a)
            rev = _review(a)
            out.append({
                "appid": appid,
                "name": name,
                "url": url,
                "image": capsule,
                "price_text": ptext,
                "price_cents": pfinal,
                "discount": pdisc,
                "review_text": rev,
                "platforms": _platforms(a),
            })
        if not rows:
            break
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
    try:
        res, err = steam_results(query, max_results)
    except Exception as e:
        res, err = None, f"steam search error: {e}"
    if not res:
        fail(f"steam search failed: {err}")
        return
    emit("steam", query, res)


if __name__ == "__main__":
    main()
