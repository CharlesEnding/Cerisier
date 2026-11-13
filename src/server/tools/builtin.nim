## Built-in tools: capabilities that need access to server state rather than a
## standalone script, so they are implemented in-process instead of through a
## `*.tool.json` manifest.
##
##   todo_write      the agent's visible checklist (widget above the chat input)
##   write_file      create a file the user can download
##   read_file       read an uploaded / generated file in pieces
##   list_files      what files exist in this conversation
##   spawn_subagent  offload a task to a fresh context (executed by the agent
##                   loop in agent/subagent.nim; only its spec lives here)
##
## They are always on, never ask for approval (they cannot leave the
## conversation's own file directory), and use the same `<tool_call>` syntax
## as every other tool. Arguments are validated with the JSON-Schema subset
## validator in tools/schema.nim.

import std/[json, options, strutils, os, base64]
import ../db/database
import ../files/files
import ./schema

type
  BuiltinSpec* = object
    name*: string
    description*: string
    inputSchema*: string
    subAgentOk*: bool    ## may a sub-agent call it?

  BuiltinEnv* = object
    db*: Database
    dataDir*: string
    convId*: int64
    messageId*: int64    ## assistant message that issued the call

  BuiltinResult* = object
    ok*: bool
    resultJson*: string  ## `{"ok": ..., "data": ...}` — stored and fed back to the model
    events*: seq[JsonNode] ## extra UI events (e.g. todo_update) to push to the browser

const
  todoToolName* = "todo_write"
  subagentToolName* = "spawn_subagent"
  maxTodoItems = 40

proc builtinSpecs*(): seq[BuiltinSpec] =
  @[
    BuiltinSpec(
      name: todoToolName,
      description: "Create or update your visible todo list. Always send the COMPLETE list; it replaces the previous one. status is pending, in_progress or completed.",
      inputSchema: """{"type":"object","required":["todos"],"properties":{"todos":{"type":"array","items":{"type":"object","required":["content","status"],"properties":{"content":{"type":"string"},"status":{"type":"string","enum":["pending","in_progress","completed"]}}}}}}""",
      subAgentOk: false),
    BuiltinSpec(
      name: subagentToolName,
      description: "Delegate a self-contained task to a sub-agent that starts with an EMPTY context and only returns a final report, so this conversation's context stays small. Put everything it needs in task/context (file names, constraints, the format you want back). Optionally restrict it to some tools.",
      inputSchema: """{"type":"object","required":["task"],"properties":{"task":{"type":"string"},"context":{"type":"string"},"tools":{"type":"array","items":{"type":"string"}}}}""",
      subAgentOk: false),
    BuiltinSpec(
      name: "write_file",
      description: "Store a file in this conversation as a download link in the chat. Only use this when the user asks for a download; to save a file at a path on disk use write_local_file instead. Text by default; use encoding \"base64\" for binary content.",
      inputSchema: """{"type":"object","required":["name","content"],"properties":{"name":{"type":"string"},"content":{"type":"string"},"encoding":{"type":"string","enum":["utf8","base64"]}}}""",
      subAgentOk: true),
    BuiltinSpec(
      name: "read_file",
      description: "Read a text file from this conversation (an upload or a file you wrote), identified by name. offset and length are in bytes; the result says whether more remains and the next offset.",
      inputSchema: """{"type":"object","required":["name"],"properties":{"name":{"type":"string"},"offset":{"type":"integer"},"length":{"type":"integer"}}}""",
      subAgentOk: true),
    BuiltinSpec(
      name: "list_files",
      description: "List the files in this conversation (uploads and generated files) with name, size and type.",
      inputSchema: """{"type":"object","properties":{}}""",
      subAgentOk: true),
  ]

proc findBuiltin*(name: string): Option[BuiltinSpec] =
  for b in builtinSpecs():
    if b.name == name:
      return some(b)
  none(BuiltinSpec)

proc isBuiltin*(name: string): bool =
  findBuiltin(name).isSome

proc builtinPromptLines*(forSubAgent: bool): seq[string] =
  result = @[]
  for b in builtinSpecs():
    if forSubAgent and not b.subAgentOk:
      continue
    result.add("- " & b.name & ": " & b.description)
    result.add("  input schema: " & b.inputSchema)

proc fail(msg: string): BuiltinResult =
  BuiltinResult(ok: false, resultJson: $(%*{"ok": false, "error": msg}), events: @[])

proc succeed(data: JsonNode, events: seq[JsonNode] = @[]): BuiltinResult =
  BuiltinResult(ok: true, resultJson: $(%*{"ok": true, "data": data}), events: events)

proc todosToJson*(items: seq[TodoRow]): JsonNode =
  result = newJArray()
  for it in items:
    result.add(%*{"content": it.content, "status": it.status})

proc runTodoWrite(env: BuiltinEnv, args: JsonNode): BuiltinResult =
  var items: seq[TodoRow] = @[]
  for t in args["todos"]:
    let content = t["content"].getStr().strip()
    if content.len == 0:
      continue
    if items.len >= maxTodoItems:
      break
    items.add((content: content, status: t["status"].getStr("pending")))
  env.db.replaceTodos(env.convId, items)
  let jsonItems = todosToJson(items)
  succeed(%*{"todos": jsonItems}, @[%*{"type": "todo_update", "items": jsonItems}])

proc runWriteFile(env: BuiltinEnv, args: JsonNode): BuiltinResult =
  let name = args["name"].getStr()
  var data = args["content"].getStr()
  if args{"encoding"}.getStr("utf8") == "base64":
    try:
      data = decode(data)
    except CatchableError:
      return fail("content is not valid base64")
  if data.len > maxUploadBytes:
    return fail("file is too large (limit " & humanSize(maxUploadBytes.int64) & ")")
  try:
    let rec = writeGeneratedFile(env.db, env.dataDir, env.convId, name, data)
    succeed(%*{"file": fileToJson(rec), "bytes_written": data.len})
  except CatchableError as e:
    fail("could not write the file: " & e.msg)

proc runReadFile(env: BuiltinEnv, args: JsonNode): BuiltinResult =
  let name = sanitizeFileName(args["name"].getStr())
  let offset = max(0, args{"offset"}.getInt(0))
  let length = max(1, min(args{"length"}.getInt(defaultReadBytes), maxReadBytes))
  let rec = env.db.findFileByName(env.convId, name)
  if rec.isNone:
    return fail("no file named '" & name & "' in this conversation (call list_files to see what exists)")
  let f = rec.get()
  let path = convDir(env.dataDir, env.convId) / f.storedName
  if not fileExists(path):
    return fail("the file is missing on the server")
  try:
    if not looksLikeText(readFileSlice(path, 0, 4096).content):
      return fail("'" & name & "' is a binary file and cannot be read as text")
    let slice = readFileSlice(path, offset, length)
    var data = %*{
      "name": f.name,
      "size": slice.total,
      "offset": offset,
      "content": slice.content,
      "truncated": slice.truncated,
    }
    if slice.truncated:
      data["next_offset"] = %(offset + slice.content.len)
    succeed(data)
  except CatchableError as e:
    fail("could not read the file: " & e.msg)

proc runListFiles(env: BuiltinEnv): BuiltinResult =
  var arr = newJArray()
  for f in env.db.listFilesForConversation(env.convId):
    arr.add(%*{
      "name": f.name,
      "size": f.size,
      "mime": f.mime,
      "origin": f.origin,
      "path": convDir(env.dataDir, env.convId) / f.storedName,
    })
  succeed(%*{"files": arr})

proc validateBuiltinArgs*(name, argsJson: string): string =
  ## Returns an error message, or "" when the arguments are valid.
  let spec = findBuiltin(name)
  if spec.isNone:
    return "unknown built-in tool: " & name
  var args: JsonNode
  try:
    args = parseJson(argsJson)
  except CatchableError as e:
    return "arguments are not valid JSON: " & e.msg
  var schemaNode: JsonNode
  try:
    schemaNode = parseJson(spec.get().inputSchema)
  except CatchableError:
    schemaNode = newJObject()
  let errors = validate(schemaNode, args)
  if errors.len > 0:
    var parts: seq[string] = @[]
    for e in errors:
      parts.add((if e.path.len > 0: e.path & ": " else: "") & e.message)
    return "invalid arguments: " & parts.join("; ")

proc runBuiltin*(env: BuiltinEnv, name, argsJson: string): BuiltinResult =
  ## Validates the arguments and runs the tool. `spawn_subagent` is executed
  ## by the agent loop (it needs the router and the approval UI), not here.
  let verr = validateBuiltinArgs(name, argsJson)
  if verr.len > 0:
    return fail(verr)
  let args = parseJson(argsJson)

  case name
  of todoToolName: runTodoWrite(env, args)
  of "write_file": runWriteFile(env, args)
  of "read_file": runReadFile(env, args)
  of "list_files": runListFiles(env)
  of subagentToolName: fail("spawn_subagent is handled by the agent loop")
  else: fail("unknown built-in tool: " & name)
