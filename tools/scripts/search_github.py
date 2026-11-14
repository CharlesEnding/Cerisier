#!/usr/bin/env python3
"""Tool: search_github. Search GitHub for repositories, users or issues.

Args: {"query": "...", "max_results": <optional int, default 10>,
       "type": <optional "repo" | "user" | "issue", default "repo">}

Uses the GitHub Search REST API (no token needed for modest usage). Each
result carries the fields the `.search-embed source-github` card needs:
repo -> name / url / description / stars / language / updated;
user -> login / url / avatar / followers;
issue -> title / url / number / repo / state.
"""
import sys
import os
import json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cerisier_search import (http_get, clean_text, truncate, emit, fail, parse_args, get_num, UA_BROWSER)


def search_repos(query, max_results):
    r = http_get("https://api.github.com/search/repositories",
                 params={"q": query, "per_page": str(max(max_results, 1)), "sort": "stars"},
                 headers={"User-Agent": UA_BROWSER, "Accept": "application/json"})
    return _api_results(r, max_results, _map_repo)


def search_users(query, max_results):
    r = http_get("https://api.github.com/search/users",
                 params={"q": query, "per_page": str(max(max_results, 1))},
                 headers={"User-Agent": UA_BROWSER, "Accept": "application/json"})
    return _api_results(r, max_results, _map_user)


def search_issues(query, max_results):
    r = http_get("https://api.github.com/search/issues",
                 params={"q": query, "per_page": str(max(max_results, 1)), "sort": "best-match"},
                 headers={"User-Agent": UA_BROWSER, "Accept": "application/json"})
    return _api_results(r, max_results, _map_issue)


def _api_results(r, max_results, mapper):
    if r.status_code != 200:
        msg = ""
        try:
            msg = r.json().get("message", "")
        except Exception:
            msg = r.text[:120]
        return None, f"github api returned {r.status_code}: {msg}"
    items = r.json().get("items", [])
    out = [mapper(i) for i in items[:max_results]]
    if not out:
        return None, "no results"
    return out, None


def _map_repo(i):
    return {
        "type": "repo",
        "name": clean_text(i.get("full_name", "")),
        "url": clean_text(i.get("html_url", "")),
        "description": truncate(clean_text(i.get("description", "")), 360) if i.get("description") else "",
        "stars": int(i.get("stargazers_count", 0) or 0),
        "forks": int(i.get("forks_count", 0) or 0),
        "language": clean_text(i.get("language", "")) or "",
        "updated": clean_text(i.get("updated_at", ""))[:10] if i.get("updated_at") else "",
        "avatar": clean_text((i.get("owner", {}) or {}).get("avatar_url", "")),
    }


def _map_user(i):
    return {
        "type": "user",
        "login": clean_text(i.get("login", "")),
        "name": clean_text(i.get("login", "")),
        "url": clean_text(i.get("html_url", "")),
        "avatar": clean_text(i.get("avatar_url", "")),
        "description": "",
    }


def _map_issue(i):
    repo = ""
    rep = i.get("repository")
    if isinstance(rep, dict):
        repo = clean_text(rep.get("full_name", ""))
    elif isinstance(rep, str):
        repo = clean_text(rep)
    if not repo:
        # fallback: parse from html_url like /owner/repo/issues/N
        url = clean_text(i.get("html_url", ""))
        parts = url.split("/")
        if len(parts) >= 5:
            repo = f"{parts[3]}/{parts[4]}"
    return {
        "type": "issue",
        "title": truncate(clean_text(i.get("title", "")), 240) or "(untitled)",
        "url": clean_text(i.get("html_url", "")),
        "number": int(i.get("number", 0) or 0),
        "repo": repo,
        "state": clean_text(i.get("state", "")),
        "description": "",
    }


def main():
    args = parse_args()
    query = args.get("query", "")
    if not isinstance(query, str) or not query.strip():
        fail("query must be a non-empty string")
        return
    query = query.strip()
    max_results = get_num(args, "max_results", 10, lo=1, hi=50)
    ttype = (args.get("type") or "repo").lower()
    if ttype not in ("repo", "user", "issue"):
        fail("type must be repo|user|issue")
        return

    fn = {"repo": search_repos, "user": search_users, "issue": search_issues}[ttype]
    try:
        res, err = fn(query, max_results)
    except Exception as e:
        res, err = None, f"{ttype} search error: {e}"
    if not res:
        fail(f"github {ttype} search failed: {err}")
        return

    emit("github", query, res, {"kind": ttype})


if __name__ == "__main__":
    main()
