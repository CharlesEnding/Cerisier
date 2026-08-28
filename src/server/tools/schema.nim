## Minimal JSON-Schema *subset* validator: enough to validate tool
## inputs/outputs without pulling in a full spec implementation.
##
## Supported keywords: `type` (string/number/integer/boolean/array/object/null,
## or an array of those), `required`, `properties`, `enum`, `items` (one
## level, applied to every array element), `additionalProperties: false`.
## Anything else in a schema is silently ignored. Not a general JSON-Schema
## implementation — oneOf/allOf/$ref/formats/pattern/etc. are all out of
## scope by design.

import std/[json, strutils]
import ../../common/types

type
  SchemaError* = object
    path*: string
    message*: string

proc err(errors: var seq[SchemaError], path, message: string) =
  errors.add(SchemaError(path: path, message: message))

proc typeMatches(node: JsonNode, expected: string): bool =
  case expected
  of "string": node.kind == JString
  of "number": node.kind in {JInt, JFloat}
  of "integer": node.kind == JInt
  of "boolean": node.kind == JBool
  of "array": node.kind == JArray
  of "object": node.kind == JObject
  of "null": node.kind == JNull
  else: true ## unknown type keyword value: don't fail closed on typos

proc validateNode(schema: JsonNode, value: JsonNode, path: string, errors: var seq[SchemaError]) =
  if schema.kind != JObject:
    return

  if schema.hasKey("type"):
    let t = schema["type"]
    var ok = false
    if t.kind == JString:
      ok = typeMatches(value, t.getStr())
    elif t.kind == JArray:
      for entry in t:
        if entry.kind == JString and typeMatches(value, entry.getStr()):
          ok = true
          break
    if not ok:
      err(errors, path, "expected type " & $t & ", got " & $value.kind)
      return ## further keyword checks below assume the type already matches

  if schema.hasKey("enum"):
    var found = false
    for allowed in schema["enum"]:
      if allowed == value:
        found = true
        break
    if not found:
      err(errors, path, "value not in enum " & $schema["enum"])

  if value.kind == JObject:
    if schema.hasKey("required"):
      for req in schema["required"]:
        if req.kind == JString and not value.hasKey(req.getStr()):
          err(errors, path, "missing required property '" & req.getStr() & "'")
    if schema.hasKey("properties") and schema["properties"].kind == JObject:
      for key, subSchema in schema["properties"].pairs:
        if value.hasKey(key):
          validateNode(subSchema, value[key], (if path.len == 0: key else: path & "." & key), errors)
    if schema{"additionalProperties"}.getBool(true) == false and schema.hasKey("properties"):
      let allowed = schema["properties"]
      for key, _ in value.pairs:
        if not allowed.hasKey(key):
          err(errors, path, "unexpected property '" & key & "'")

  if value.kind == JArray and schema.hasKey("items"):
    for i, item in value.elems:
      validateNode(schema["items"], item, path & "[" & $i & "]", errors)

proc validate*(schema: JsonNode, value: JsonNode): seq[SchemaError] =
  result = @[]
  validateNode(schema, value, "", result)

proc parseSchemaOrEmpty(raw: string): JsonNode =
  if raw.strip().len == 0:
    return newJObject()
  try:
    parseJson(raw)
  except CatchableError:
    newJObject()

proc validateArgs*(manifest: ToolManifest, argsJson: string): seq[SchemaError] =
  var parsed: JsonNode
  try:
    parsed = parseJson(argsJson)
  except CatchableError as e:
    return @[SchemaError(path: "", message: "arguments are not valid JSON: " & e.msg)]
  validate(parseSchemaOrEmpty(manifest.inputSchema), parsed)

proc validateOutput*(manifest: ToolManifest, dataJson: JsonNode): seq[SchemaError] =
  validate(parseSchemaOrEmpty(manifest.outputSchema), dataJson)
