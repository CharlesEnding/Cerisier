## Parses `<tool_call><function=NAME><parameter=KEY>VALUE</parameter></function></tool_call>`
## (Qwen's native format) out of raw LLM text; the older JSON body
## `{"name": "...", "arguments": {...}}` is still accepted. Non-nested, simple
## scan similar in spirit to ../formats/formats.nim's tag scanner.

import std/[json, options, strutils]
import ./registry
import ./builtin

type
  ParsedToolCall* = object
    name*: string
    argsJson*: string
    malformed*: bool      ## true if the tag body wasn't valid `{"name":..,"arguments":{..}}`
    error*: string        ## set when malformed

const
  openTag = "<tool_call>"
  closeTag = "</tool_call>"

const
  fnOpen = "<function="
  fnClose = "</function>"
  paramOpen = "<parameter="
  paramClose = "</parameter>"

const expectedForm = "expected exactly <tool_call>\n<function=tool_name>\n<parameter=param_name>\nvalue\n</parameter>\n</function>\n</tool_call>"

proc inputSchemaOf(reg: ToolRegistry, name: string): JsonNode =
  ## The tool's input schema, or nil when the tool is unknown.
  var raw = ""
  let b = findBuiltin(name)
  if b.isSome:
    raw = b.get().inputSchema
  elif reg != nil:
    try: raw = reg.find(name).inputSchema
    except KeyError: discard
  if raw.len == 0:
    return nil
  try: parseJson(raw)
  except CatchableError: nil

proc parseXmlCall(body: string, reg: ToolRegistry): ParsedToolCall =
  ## Qwen form: `<function=NAME>` then `<parameter=KEY>VALUE</parameter>` per argument.
  let nameEnd = body.find('>', fnOpen.len)
  if nameEnd < 0:
    raise newException(ValueError, "unterminated <function=...> tag")
  let name = body[fnOpen.len ..< nameEnd].strip()
  if name.len == 0:
    raise newException(ValueError, "empty function name")
  let schema = inputSchemaOf(reg, name)
  var args = newJObject()
  var pos = nameEnd + 1
  while true:
    let pOpen = body.find(paramOpen, pos)
    if pOpen < 0:
      break
    let keyEnd = body.find('>', pOpen + paramOpen.len)
    if keyEnd < 0:
      raise newException(ValueError, "unterminated <parameter=...> tag")
    let key = body[pOpen + paramOpen.len ..< keyEnd].strip()
    let valEnd = body.find(paramClose, keyEnd + 1)
    if valEnd < 0:
      raise newException(ValueError, "missing </parameter> for '" & key & "'")
    var val = body[keyEnd + 1 ..< valEnd]
    if val.startsWith("\n"): val = val[1 .. ^1]
    if val.endsWith("\n"): val.setLen(val.len - 1)
    pos = valEnd + paramClose.len
    # The schema decides: declared strings stay raw, anything else is read as JSON.
    let declared = if schema != nil: schema{"properties"}{key}{"type"}.getStr("") else: ""
    let t = val.strip()
    var node = newJString(val)
    let jsonLike = t.len > 0 and (t[0] in {'{', '[', '-'} or t[0] in Digits or t in ["true", "false", "null"])
    if declared != "string" and (declared.len > 0 or (schema == nil and jsonLike)):
      try: node = parseJson(t)
      except CatchableError: discard
    args[key] = node
  # Tolerate `<parameter=arguments>{...}</parameter>` wrapping the whole argument object.
  if args.len == 1 and args.hasKey("arguments") and args["arguments"].kind == JObject and
     (schema == nil or schema{"properties"}{"arguments"}.isNil):
    args = args["arguments"]
  ParsedToolCall(name: name, argsJson: $args)

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

proc parseToolCalls*(text: string, reg: ToolRegistry = nil): seq[ParsedToolCall] =
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
    let snippet = if body.len > 160: body[0 ..< 160] & "..." else: body
    if body.startsWith(fnOpen):
      try:
        result.add(parseXmlCall(body, reg))
      except CatchableError as e:
        result.add(ParsedToolCall(malformed: true,
          error: "malformed tool_call (" & e.msg & "); you wrote: " & snippet & " -- " & expectedForm))
      continue
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
        result.add(ParsedToolCall(malformed: true,
          error: "malformed tool_call (" & e.msg & "); you wrote: " & snippet & " -- " & expectedForm))

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
