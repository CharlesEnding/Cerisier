## Formats: data-driven inline markup the LLM is instructed to emit, parsed
## into styled spans for the web UI. Tag -> CSS class mapping lives in the
## `formats` DB table so new tags can be added without a code change.
##
## Syntax: [[tag:param]]...[[/tag]]  (param optional: [[tag]]...[[/tag]])
## Chosen to avoid clashing with markdown/code fences.

import std/[strutils, options, json]
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

proc seedDefaultFormats*(db: Database) =
  ## First run only (table empty): a few ready-made named styles whose CSS
  ## classes ship in style.css. The model can always use the built-in
  ## `[[color:..]]` / `[[bg:..]]` tags without any of these.
  if db.listFormats().len > 0:
    return
  db.upsertFormat("date", "fmt-date", "dates, years and time periods")
  db.upsertFormat("person", "fmt-person", "people and named characters")
  db.upsertFormat("place", "fmt-place", "places and locations")
  db.upsertFormat("term", "fmt-term", "key terms and definitions")
  db.upsertFormat("warn", "fmt-warn", "warnings, risks and caveats")

proc formatsJson*(db: Database): string =
  ## `{"tag": "css-class", ...}` handed to the browser (window.CERISIER_FORMATS)
  ## so rich.js knows which `[[tag]]...[[/tag]]` names are valid.
  var node = newJObject()
  for d in listFormatDefs(db):
    node[d.tag] = %(d.cssClass)
  $node

proc formatsPromptFragment*(db: Database): string =
  ## System-prompt text telling the model what the chat UI can render.
  var lines: seq[string] = @[]
  lines.add("## Output formatting")
  lines.add("Your replies are rendered as Markdown: headings, lists, tables, **bold**, *italic*, links, and fenced code blocks with a language tag (for example ```python or ```nim).")
  lines.add("""Math is rendered from LaTeX: inline $x^2$ and display $$\frac{a}{b}$$. Inside math, \color{red}{x} or \textcolor{#4a90d9}{y} colours part of an equation.""")
  lines.add("Colour makes dense topics easier to scan. Wrap text in [[color:#e06c75]]text[[/color]] (any CSS colour) or highlight it with [[bg:#ffd54f]]text[[/bg]]. Give each variable, faction, person or date its own consistent colour, say what each colour means the first time, and use colour sparingly. Keep a tag inside one paragraph and do not use these tags inside code blocks.")
  let defs = listFormatDefs(db)
  if defs.len > 0:
    lines.add("Named styles (use as [[name]]text[[/name]]):")
    for d in defs:
      let desc = if d.description.len > 0: d.description else: d.cssClass
      lines.add("- " & d.tag & ": " & desc)
  lines.join("\n")

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
