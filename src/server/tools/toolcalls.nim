## Parses `<tool_call>{"name": "...", "arguments": {...}}</tool_call>` tags
## out of raw LLM text output. Custom, model-agnostic convention (no native
## function-calling) — see plan decisions. Non-nested, simple scan similar
## in spirit to ../formats/formats.nim's tag scanner.

import std/[json, strutils]

type
  ParsedToolCall* = object
    name*: string
    argsJson*: string
    malformed*: bool      ## true if the tag body wasn't valid `{"name":..,"arguments":{..}}`
    error*: string        ## set when malformed

const
  openTag = "<tool_call>"
  closeTag = "</tool_call>"

proc parseToolCalls*(text: string): seq[ParsedToolCall] =
  result = @[]
  var pos = 0
  while true:
    let openIdx = text.find(openTag, pos)
    if openIdx < 0:
      break
    let bodyStart = openIdx + openTag.len
    let closeIdx = text.find(closeTag, bodyStart)
    if closeIdx < 0:
      break ## unterminated tag: stop scanning, treat as no more calls
    let body = text[bodyStart ..< closeIdx].strip()
    pos = closeIdx + closeTag.len
    try:
      let node = parseJson(body)
      let name = node{"name"}.getStr("")
      if name.len == 0:
        result.add(ParsedToolCall(malformed: true, error: "missing 'name' field"))
      else:
        let args = node{"arguments"}
        let argsJson = if args != nil: $args else: "{}"
        result.add(ParsedToolCall(name: name, argsJson: argsJson))
    except CatchableError as e:
      result.add(ParsedToolCall(malformed: true, error: "malformed tool_call JSON: " & e.msg))

proc stripToolCalls*(text: string): string =
  result = ""
  var pos = 0
  while true:
    let openIdx = text.find(openTag, pos)
    if openIdx < 0:
      result.add(text[pos ..< text.len])
      break
    let closeIdx = text.find(closeTag, openIdx + openTag.len)
    if closeIdx < 0:
      result.add(text[pos ..< text.len])
      break
    result.add(text[pos ..< openIdx])
    pos = closeIdx + closeTag.len
  result = result.strip()
