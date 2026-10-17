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

const expectedForm = """expected exactly <tool_call>{"name": "tool_name", "arguments": {...}}</tool_call>"""

proc parseBareNameCall(body: string): ParsedToolCall =
  ## Lenient fallback for models that write `{"tool", "arguments": {...}}` or
  ## `{"tool", {...}}` (tool name as a bare first element, no "name" key).
  var i = 1
  while i < body.len and body[i] in Whitespace: inc i
  if i >= body.len or body[i] != '"':
    raise newException(ValueError, "not a bare-name call")
  let nameEnd = body.find('"', i + 1)
  if nameEnd < 0:
    raise newException(ValueError, "not a bare-name call")
  let name = body[i + 1 ..< nameEnd]
  if name.len == 0 or not name.allCharsInSet(IdentChars):
    raise newException(ValueError, "not a bare-name call")
  var j = nameEnd + 1
  while j < body.len and body[j] in Whitespace: inc j
  if j >= body.len or body[j] notin {',', '}'}:
    raise newException(ValueError, "not a bare-name call")
  var rest = if body[j] == ',': body[j + 1 .. ^1].strip() else: ""
  if rest.endsWith("}"):
    rest.setLen(rest.len - 1)
  rest = rest.strip()
  var args = newJObject()
  if rest.len > 0:
    let node = parseJson(if rest.startsWith("{"): rest else: "{" & rest & "}")
    args = if node.hasKey("arguments"): node["arguments"] else: node
  ParsedToolCall(name: name, argsJson: $args)

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
      try:
        result.add(parseBareNameCall(body))
      except CatchableError:
        let snippet = if body.len > 160: body[0 ..< 160] & "..." else: body
        result.add(ParsedToolCall(malformed: true,
          error: "malformed tool_call JSON (" & e.msg & "); you wrote: " & snippet & " -- " & expectedForm))

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
