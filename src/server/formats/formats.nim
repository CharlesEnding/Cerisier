## Formats: data-driven inline markup the LLM is instructed to emit, parsed
## into styled spans for the web UI. Tag -> CSS class mapping lives in the
## `formats` DB table so new tags can be added without a code change.
##
## Syntax: [[tag:param]]...[[/tag]]  (param optional: [[tag]]...[[/tag]])
## Chosen to avoid clashing with markdown/code fences.

import std/[strutils, options]
import ../db/database

type
  FormatSpan* = object
    tag*: string
    param*: string
    text*: string
    plain*: bool  ## true for a run of untagged text

  FormatDef* = object
    tag*: string
    cssClass*: string
    description*: string

proc listFormatDefs*(db: Database): seq[FormatDef] =
  result = @[]
  for (_, tag, cssClass, desc) in db.listFormats():
    result.add(FormatDef(tag: tag, cssClass: cssClass, description: desc))

proc saveFormat*(db: Database, tag, cssClass, description: string) =
  db.upsertFormat(tag, cssClass, description)

proc removeFormat*(db: Database, id: int64) =
  db.deleteFormat(id)

proc findOpenTag(s: string, start: int): Option[(int, int, string, string)] =
  ## Returns (openStart, openEnd, tag, param) for the next `[[tag[:param]]]`
  ## found at or after `start`.
  let idx = s.find("[[", start)
  if idx < 0:
    return none((int, int, string, string))
  let closeIdx = s.find("]]", idx)
  if closeIdx < 0:
    return none((int, int, string, string))
  let inner = s[idx + 2 ..< closeIdx]
  if inner.startsWith("/"):
    return findOpenTag(s, closeIdx + 2) # skip stray closing tags
  let parts = inner.split(':', maxsplit = 1)
  let tag = parts[0]
  let param = if parts.len > 1: parts[1] else: ""
  some((idx, closeIdx + 2, tag, param))

proc parseFormats*(s: string): seq[FormatSpan] =
  ## Minimal non-nested tag parser: finds `[[tag:param]]...[[/tag]]` spans,
  ## everything else becomes plain runs.
  result = @[]
  var pos = 0
  while pos < s.len:
    let openOpt = findOpenTag(s, pos)
    if openOpt.isNone:
      result.add(FormatSpan(plain: true, text: s[pos ..< s.len]))
      break
    let (openStart, openEnd, tag, param) = openOpt.get()
    if openStart > pos:
      result.add(FormatSpan(plain: true, text: s[pos ..< openStart]))
    let closeTag = "[[/" & tag & "]]"
    let closeIdx = s.find(closeTag, openEnd)
    if closeIdx < 0:
      # unterminated tag: treat the rest as plain text
      result.add(FormatSpan(plain: true, text: s[openEnd ..< s.len]))
      pos = s.len
    else:
      result.add(FormatSpan(tag: tag, param: param, text: s[openEnd ..< closeIdx], plain: false))
      pos = closeIdx + closeTag.len
