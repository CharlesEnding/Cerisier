## Orchestrates a single tool call through its lifecycle:
## pending_approval -> approved -> running -> succeeded/failed/timeout/
## denied/killed/validation_failed/protocol_error.
##
## The approval UI must be given the full tool name + exact argsJson so the
## user can see precisely what will run before approving (mandatory unless
## the tool's permission is `auto`, or a per-conversation "always allow"
## override has been set from the chat UI).
##
## `execute()` is async so a running local tool call can be interrupted by
## a manual "kill" request from chat: the wait loop yields via
## `sleepAsync` between polls instead of blocking the whole event loop for
## the tool's entire runtime.

import std/[json, tables, strutils, asyncdispatch, options, osproc]
import ../db/database
import ../../common/types
import ./registry
import ./runner_local
import ./runner_remote
import ./schema

type
  ToolExecutor* = ref object
    db: Database
    registry*: ToolRegistry
    companions: CompanionRegistry
    runningProcesses: Table[int64, Process]
    killRequested: Table[int64, bool]
    sessionPermissions: Table[int64, Table[string, ToolPermission]] ## convId -> toolName -> override

proc newToolExecutor*(db: Database, registry: ToolRegistry, companions: CompanionRegistry): ToolExecutor =
  ToolExecutor(db: db, registry: registry, companions: companions,
    runningProcesses: initTable[int64, Process](),
    killRequested: initTable[int64, bool](),
    sessionPermissions: initTable[int64, Table[string, ToolPermission]]())

proc schemaErrorsMsg(errors: seq[SchemaError]): string =
  var parts: seq[string] = @[]
  for e in errors:
    let where = if e.path.len > 0: e.path & ": " else: ""
    parts.add(where & e.message)
  parts.join("; ")

proc effectivePermission*(ex: ToolExecutor, convId: int64, toolName: string, manifest: ToolManifest): ToolPermission =
  if ex.sessionPermissions.hasKey(convId) and ex.sessionPermissions[convId].hasKey(toolName):
    return ex.sessionPermissions[convId][toolName]
  manifest.permission

proc setSessionPermission*(ex: ToolExecutor, convId: int64, toolName: string, permission: ToolPermission) =
  if not ex.sessionPermissions.hasKey(convId):
    ex.sessionPermissions[convId] = initTable[string, ToolPermission]()
  ex.sessionPermissions[convId][toolName] = permission

proc requestToolCall*(ex: ToolExecutor, convId, messageId: int64, toolName, argsJson: string): int64 =
  ## Always creates a tool_calls row. Resolves the effective permission
  ## (session override, else the manifest's own) and, for `auto`/`deny`,
  ## immediately drives the row to a terminal state without ever prompting
  ## the chat UI — `ask` (the default) leaves it `pending_approval` for the
  ## caller to surface an inline approve/deny prompt.
  var manifest: ToolManifest
  try:
    manifest = ex.registry.find(toolName)
  except KeyError:
    let id = ex.db.createToolCall(messageId, toolName, "local", argsJson)
    ex.db.setToolCallResult(id, $tcsFailed, $(%*{"ok": false, "error": "unknown tool: " & toolName}))
    return id

  let id = ex.db.createToolCall(messageId, toolName, $manifest.location, argsJson)
  case ex.effectivePermission(convId, toolName, manifest)
  of ptDeny:
    ex.db.setToolCallResult(id, $tcsDenied, $(%*{"ok": false, "error": "tool is disabled (permission=deny)"}))
  of ptAuto:
    let errors = validateArgs(manifest, argsJson)
    if errors.len > 0:
      ex.db.setToolCallResult(id, $tcsValidationFailed, $(%*{"ok": false, "error": schemaErrorsMsg(errors)}))
    else:
      ex.db.setToolCallStatus(id, $tcsApproved)
  of ptAsk:
    discard ## stays pending_approval; caller prompts the chat UI
  id

proc approve*(ex: ToolExecutor, toolCallId: int64) =
  ex.db.setToolCallStatus(toolCallId, $tcsApproved)

proc deny*(ex: ToolExecutor, toolCallId: int64) =
  ex.db.setToolCallResult(toolCallId, $tcsDenied, $(%*{"ok": false, "error": "denied by user"}))

proc killToolCall*(ex: ToolExecutor, toolCallId: int64) =
  ## No-op if the call isn't currently tracked as running (e.g. already
  ## finished, or never started) — `deny()` already covers the
  ## not-yet-running case.
  ex.killRequested[toolCallId] = true

proc execute*(ex: ToolExecutor, toolCallId: int64, toolName, argsJson: string) {.async.} =
  ## Runs an already-approved tool call and records the result. Re-validates
  ## input against the schema (defense in depth: args could have been
  ## hand-edited, or the manifest could have changed, between request and
  ## approval).
  var manifest: ToolManifest
  try:
    manifest = ex.registry.find(toolName)
  except KeyError:
    ex.db.setToolCallResult(toolCallId, $tcsFailed, $(%*{"ok": false, "error": "unknown tool: " & toolName}))
    return

  let inputErrors = validateArgs(manifest, argsJson)
  if inputErrors.len > 0:
    ex.db.setToolCallResult(toolCallId, $tcsValidationFailed, $(%*{"ok": false, "error": schemaErrorsMsg(inputErrors)}))
    return

  case manifest.location
  of tlRemote:
    let companion = ex.companions.findCompanionFor(toolName)
    if companion.isNone:
      ex.db.setToolCallResult(toolCallId, $tcsFailed, $(%*{"ok": false, "error": "no companion agent connected for this tool"}))
    else:
      # Actual dispatch over the WebSocket happens in the web layer, which
      # calls submitResult/takeResult on the shared CompanionRegistry; this
      # proc only marks the intent so the caller can await it there.
      discard
  of tlLocal:
    ex.db.setToolCallStatus(toolCallId, $tcsRunning)
    let p = startLocal(manifest, argsJson)
    ex.runningProcesses[toolCallId] = p

    var waited = 0
    const stepMs = 50
    var killed = false
    var timedOut = false
    while p.running():
      if ex.killRequested.getOrDefault(toolCallId, false):
        p.kill()
        killed = true
        break
      if waited >= manifest.timeoutMs:
        p.kill()
        timedOut = true
        break
      await sleepAsync(stepMs)
      waited += stepMs

    ex.runningProcesses.del(toolCallId)
    ex.killRequested.del(toolCallId)
    let output = readAndClose(p)

    if killed:
      ex.db.setToolCallResult(toolCallId, $tcsKilled, $(%*{"ok": false, "error": "killed by user"}))
      return
    if timedOut:
      ex.db.setToolCallResult(toolCallId, $tcsTimeout, $(%*{"ok": false, "error": "timed out after " & $manifest.timeoutMs & "ms"}))
      return

    var resultNode: JsonNode
    try:
      resultNode = parseJson(output.strip())
    except CatchableError:
      ex.db.setToolCallResult(toolCallId, $tcsProtocolError,
        $(%*{"ok": false, "error": "tool did not print a valid JSON result object; raw output: " & output}))
      return

    if resultNode.kind != JObject or not resultNode.hasKey("ok"):
      ex.db.setToolCallResult(toolCallId, $tcsProtocolError,
        $(%*{"ok": false, "error": "tool result missing required 'ok' field; raw output: " & output}))
      return

    let ok = if resultNode["ok"].kind == JBool: resultNode["ok"].getBool() else: false
    if not ok:
      let errMsg = if resultNode.hasKey("error") and resultNode["error"].kind == JString:
                     resultNode["error"].getStr()
                   else: "tool reported failure"
      ex.db.setToolCallResult(toolCallId, $tcsFailed, $(%*{"ok": false, "error": errMsg}))
      return

    let dataNode = if resultNode.hasKey("data"): resultNode["data"] else: newJNull()
    let outputErrors = validateOutput(manifest, dataNode)
    if outputErrors.len > 0:
      ex.db.setToolCallResult(toolCallId, $tcsValidationFailed, $(%*{"ok": false, "error": schemaErrorsMsg(outputErrors)}))
      return

    ex.db.setToolCallResult(toolCallId, $tcsSucceeded, $(%*{"ok": true, "data": dataNode}))

