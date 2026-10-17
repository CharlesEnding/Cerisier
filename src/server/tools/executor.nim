## Orchestrates a single tool call through its lifecycle:
## pending_approval -> approved -> running -> succeeded/failed/timeout/
## denied/killed/validation_failed/protocol_error.
##
## The approval UI must be given the full tool name + exact argsJson so the
## user can see precisely what will run before approving (mandatory unless
## the tool's permission is `auto`, or a per-conversation "always allow"
## override has been set from the chat UI).
##
## WHERE a call runs is decided once, when the call is requested, from the
## conversation's "Run tools on" setting (default / server / client) and the
## tool's manifest `location` (see `resolveTarget` in common/types.nim). The
## decision is stored in `tool_calls.location` ("server" | "client"):
##   * server: spawned by this process via osproc (runner_local)
##   * client: sent over WebSocket to a connected cerisier-agent (runner_remote)
##
## `execute()` is async so a running tool call can be interrupted by a manual
## "kill" request from chat: the wait loops yield via `sleepAsync` between
## polls instead of blocking the whole event loop for the tool's runtime.

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

  ApprovalHook* = proc(toolCallId: int64, toolName, argsJson, target: string): Future[void] {.gcsafe.}
    ## Shows an approve/deny prompt for a `pending_approval` call and returns
    ## once the user has decided *and* (if approved) the call has finished.

  DispatchResult* = object
    id*: int64
    status*: string
    resultJson*: string

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

proc failure(msg: string): string =
  $(%*{"ok": false, "error": msg})

proc effectivePermission*(ex: ToolExecutor, convId: int64, toolName: string, manifest: ToolManifest): ToolPermission =
  if ex.sessionPermissions.hasKey(convId) and ex.sessionPermissions[convId].hasKey(toolName):
    return ex.sessionPermissions[convId][toolName]
  manifest.permission

proc setSessionPermission*(ex: ToolExecutor, convId: int64, toolName: string, permission: ToolPermission) =
  if not ex.sessionPermissions.hasKey(convId):
    ex.sessionPermissions[convId] = initTable[string, ToolPermission]()
  ex.sessionPermissions[convId][toolName] = permission

proc conversationTargetPref(ex: ToolExecutor, convId: int64): ToolTargetPref =
  try:
    parseEnum[ToolTargetPref](ex.db.getConversationToolTarget(convId))
  except ValueError:
    ttpDefault

proc targetFromRecorded(recorded: string, manifest: ToolManifest): ExecTarget =
  case recorded
  of "server": etServer
  of "client": etClient
  else: manifestTarget(manifest.location) ## rows written before the chat option existed ("local"/"remote")

proc requestToolCall*(ex: ToolExecutor, convId, messageId: int64, toolName, argsJson: string): int64 =
  ## Always creates a tool_calls row. Resolves the effective permission
  ## (session override, else the manifest's own) and, for `auto`/`deny`,
  ## immediately drives the row to a terminal state or to `approved` without
  ## ever prompting the chat UI — `ask` (the default) leaves it
  ## `pending_approval` for the caller to surface an inline approve/deny prompt.
  var manifest: ToolManifest
  try:
    manifest = ex.registry.find(toolName)
  except KeyError:
    let id = ex.db.createToolCall(messageId, toolName, $etServer, argsJson)
    ex.db.setToolCallResult(id, $tcsFailed, failure("unknown tool: " & toolName))
    return id

  let target = resolveTarget(ex.conversationTargetPref(convId), manifest.location)
  let id = ex.db.createToolCall(messageId, toolName, $target, argsJson)
  case ex.effectivePermission(convId, toolName, manifest)
  of ptDeny:
    ex.db.setToolCallResult(id, $tcsDenied, failure("tool is disabled (permission=deny)"))
  of ptAuto:
    let errors = validateArgs(manifest, argsJson)
    if errors.len > 0:
      ex.db.setToolCallResult(id, $tcsValidationFailed, failure(schemaErrorsMsg(errors)))
    else:
      ex.db.setToolCallStatus(id, $tcsApproved)
  of ptAsk:
    discard ## stays pending_approval; caller prompts the chat UI
  id

proc approve*(ex: ToolExecutor, toolCallId: int64) =
  ex.db.setToolCallStatus(toolCallId, $tcsApproved)

proc deny*(ex: ToolExecutor, toolCallId: int64) =
  ex.db.setToolCallResult(toolCallId, $tcsDenied, failure("denied by user"))

proc killToolCall*(ex: ToolExecutor, toolCallId: int64) =
  ## No-op if the call isn't currently tracked as running (e.g. already
  ## finished, or never started) — `deny()` already covers the
  ## not-yet-running case.
  ex.killRequested[toolCallId] = true

proc finishWithOutput(ex: ToolExecutor, toolCallId: int64, manifest: ToolManifest, output: string) =
  ## Shared by server and client execution: the tool printed one JSON object
  ## `{"ok": bool, "data": ..., "error": ...}`; validate it and record it.
  var resultNode: JsonNode
  try:
    resultNode = parseJson(output.strip())
  except CatchableError:
    ex.db.setToolCallResult(toolCallId, $tcsProtocolError,
      failure("tool did not print a valid JSON result object; raw output: " & output))
    return

  if resultNode.kind != JObject or not resultNode.hasKey("ok"):
    ex.db.setToolCallResult(toolCallId, $tcsProtocolError,
      failure("tool result missing required 'ok' field; raw output: " & output))
    return

  let ok = if resultNode["ok"].kind == JBool: resultNode["ok"].getBool() else: false
  if not ok:
    let errMsg = if resultNode.hasKey("error") and resultNode["error"].kind == JString:
                   resultNode["error"].getStr()
                 else: "tool reported failure"
    ex.db.setToolCallResult(toolCallId, $tcsFailed, failure(errMsg))
    return

  let dataNode = if resultNode.hasKey("data"): resultNode["data"] else: newJNull()
  let outputErrors = validateOutput(manifest, dataNode)
  if outputErrors.len > 0:
    ex.db.setToolCallResult(toolCallId, $tcsValidationFailed, failure(schemaErrorsMsg(outputErrors)))
    return

  ex.db.setToolCallResult(toolCallId, $tcsSucceeded, $(%*{"ok": true, "data": dataNode}))

proc executeOnServer(ex: ToolExecutor, toolCallId: int64, manifest: ToolManifest, argsJson: string) {.async.} =
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
    ex.db.setToolCallResult(toolCallId, $tcsKilled, failure("killed by user"))
    return
  if timedOut:
    ex.db.setToolCallResult(toolCallId, $tcsTimeout, failure("timed out after " & $manifest.timeoutMs & "ms"))
    return
  finishWithOutput(ex, toolCallId, manifest, output)

proc executeOnClient(ex: ToolExecutor, toolCallId: int64, manifest: ToolManifest, argsJson: string) {.async.} =
  ## Sends the job to a connected cerisier-agent that advertises this tool
  ## name and polls for its reply (the /ws/agent route files results into the
  ## CompanionRegistry). The agent enforces the tool's own timeout; the server
  ## allows a small grace period on top before giving up.
  let companion = ex.companions.findCompanionFor(manifest.name)
  if companion.isNone:
    ex.db.setToolCallResult(toolCallId, $tcsFailed, failure(
      "no connected client agent provides the tool '" & manifest.name &
      "'. Start cerisier-agent on the client machine (with this tool in its tools directory), " &
      "or set \"Run tools on\" to Server."))
    return
  let cid = companion.get()
  let job = makeJob(manifest.name, argsJson)
  ex.db.setToolCallStatus(toolCallId, $tcsRunning)
  try:
    await ex.companions.sendTo(cid, job.toWire())
  except CatchableError as e:
    ex.db.setToolCallResult(toolCallId, $tcsFailed, failure("could not send the job to the client agent: " & e.msg))
    return

  var waited = 0
  const stepMs = 50
  var killed = false
  var timedOut = false
  var reply = none(RemoteJobResult)
  while true:
    reply = ex.companions.takeResult(job.id)
    if reply.isSome:
      break
    if not ex.companions.companions.hasKey(cid):
      break ## agent disconnected mid-job
    if ex.killRequested.getOrDefault(toolCallId, false):
      killed = true
    elif waited >= manifest.timeoutMs + 3000:
      timedOut = true
    if killed or timedOut:
      try:
        await ex.companions.sendTo(cid, $(%*{"type": "kill_tool", "id": job.id}))
      except CatchableError:
        discard
      break
    await sleepAsync(stepMs)
    waited += stepMs

  ex.killRequested.del(toolCallId)
  if killed:
    ex.db.setToolCallResult(toolCallId, $tcsKilled, failure("killed by user"))
  elif timedOut:
    ex.db.setToolCallResult(toolCallId, $tcsTimeout, failure("timed out after " & $manifest.timeoutMs & "ms"))
  elif reply.isNone:
    ex.db.setToolCallResult(toolCallId, $tcsFailed, failure("the client agent disconnected before returning a result"))
  else:
    finishWithOutput(ex, toolCallId, manifest, reply.get().output)

proc execute*(ex: ToolExecutor, toolCallId: int64, toolName, argsJson: string) {.async.} =
  ## Runs an already-approved tool call and records the result. Re-validates
  ## input against the schema (defense in depth: args could have been
  ## hand-edited, or the manifest could have changed, between request and
  ## approval).
  var manifest: ToolManifest
  try:
    manifest = ex.registry.find(toolName)
  except KeyError:
    ex.db.setToolCallResult(toolCallId, $tcsFailed, failure("unknown tool: " & toolName))
    return

  let inputErrors = validateArgs(manifest, argsJson)
  if inputErrors.len > 0:
    ex.db.setToolCallResult(toolCallId, $tcsValidationFailed, failure(schemaErrorsMsg(inputErrors)))
    return

  case targetFromRecorded(ex.db.getToolCallLocation(toolCallId), manifest)
  of etServer:
    await ex.executeOnServer(toolCallId, manifest, argsJson)
  of etClient:
    await ex.executeOnClient(toolCallId, manifest, argsJson)

proc dispatchToolCall*(ex: ToolExecutor, convId, messageId: int64, toolName, argsJson: string,
                       askUser: ApprovalHook): Future[DispatchResult] {.async.} =
  ## The one entry point the agent loops use (main chat and sub-agents):
  ## request the call, then either
  ##   * `pending_approval` -> hand it to `askUser`, which resolves after the
  ##     user decided and (when approved) the approve handler ran it, or
  ##   * `approved` (auto permission / "approve always") -> run it right here.
  ## Terminal states (denied, validation_failed, unknown tool) need nothing more.
  let id = ex.requestToolCall(convId, messageId, toolName, argsJson)
  var row = ex.db.getToolCall(id)
  if row.status == $tcsPendingApproval:
    await askUser(id, toolName, argsJson, ex.db.getToolCallLocation(id))
    row = ex.db.getToolCall(id)
  elif row.status == $tcsApproved:
    await ex.execute(id, toolName, argsJson)
    row = ex.db.getToolCall(id)
  DispatchResult(id: id, status: row.status, resultJson: row.resultJson)
