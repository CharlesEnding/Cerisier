## Orchestrates a single tool call through its lifecycle:
## pending_approval -> approved -> running -> succeeded/failed/timeout/
## denied/killed/validation_failed/protocol_error.
##
## The approval UI must be given the full tool name + exact argsJson so the
## user can see precisely what will run before approving (mandatory unless
## the tool's permission is `auto`, or a per-conversation "always allow"
## override has been set from the chat UI).
##
## Every tool runs on this machine, spawned via osproc (runner_local).
##
## `execute()` is async so a running tool call can be interrupted by a manual
## "kill" request from chat: the wait loops yield via `wakeAfter` between
## polls instead of blocking the whole event loop for the tool's runtime.

import std/[json, tables, strutils, asyncdispatch, options, osproc, os, monotimes, times]
import ../db/database
import ../../common/types
import ./registry
import ./runner_local
import ./schema

type
  ToolExecutor* = ref object
    db: Database
    registry*: ToolRegistry
    runningProcesses: Table[int64, Process]
    killRequested: Table[int64, bool]
    sessionPermissions: Table[int64, Table[string, ToolPermission]] ## convId -> toolName -> override

  ApprovalHook* = proc(toolCallId: int64, toolName, argsJson: string): Future[void] {.gcsafe.}
    ## Shows an approve/deny prompt for a `pending_approval` call and returns
    ## once the user has decided *and* (if approved) the call has finished.

  DispatchResult* = object
    id*: int64
    status*: string
    resultJson*: string

proc newToolExecutor*(db: Database, registry: ToolRegistry): ToolExecutor =
  ToolExecutor(db: db, registry: registry,
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

proc workingDirFor*(ex: ToolExecutor, convId: int64): string =
  ## The conversation's stored working directory, or "" when unset. Read from
  ## the DB, never from the model, so the model cannot steer the gate or the
  ## subprocess cwd by lying about a path.
  ex.db.getConversationWorkingDir(convId)

proc resolveWithin(workdir, candidate: string): bool =
  ## True when `candidate`, after normalising `..`/`.` via absolutePath,
  ## still lies at or under `workdir`. absolutePath works on paths that don't
  ## exist yet, so a write to a new file inside the dir is judged correctly.
  let real = absolutePath(candidate, workdir)
  return real == workdir or real.startsWith(workdir & DirSep)

proc isWithinWorkingDir*(workdir, manifestPathArgs: string, argsJson: string): bool =
  ## Decide whether every declared filesystem-path argument in this call
  ## resolves under `workdir`. Returns false (force approval) when `workdir`
  ## is unset, so an unset working directory never auto-approves anything.
  ##
  ## `manifestPathArgs` is the comma-separated list of arg names taken from
  ## the manifest's `path_args`. A tool with no path_args has nothing to
  ## constrain and is therefore treated as *not* provably in the directory
  ## (fail closed) — callers that want cwd-bound auto-approval (e.g.
  ## run_command) must opt in explicitly, which is why those tools keep
  ## `ask`.
  ##
  ## Note: containment is decided by lexical path normalisation, so `..`
  ## traversal and absolute paths are caught; a symlink that points outside
  ## the working directory is not (a deeper threat model that the sandboxed
  ## working dir is expected to mitigate).
  if workdir.len == 0:
    return false
  let names = manifestPathArgs.split(",")
  if names.len == 0 or (names.len == 1 and names[0].strip().len == 0):
    return false
  var args: JsonNode
  try:
    args = parseJson(argsJson)
  except CatchableError:
    return false
  if args.kind != JObject:
    return false
  let wd = absolutePath(workdir)
  for name in names:
    let key = name.strip()
    if key.len == 0:
      continue
    if not args.hasKey(key):
      continue ## absent optional path arg: nothing outside the dir to worry about
    let val = args[key]
    if val.kind != JString:
      return false
    let p = val.getStr()
    if p.len == 0:
      return false
    ## absolutePath resolves a relative `p` against `wd`; an absolute `p`
    ## is returned normalised (base ignored).
    let target = absolutePath(p, wd)
    if not resolveWithin(wd, target):
      return false
  return true

proc requestToolCall*(ex: ToolExecutor, convId, messageId: int64, toolName, argsJson: string): int64 =
  ## Always creates a tool_calls row. Resolves the effective permission
  ## (session override, else the manifest's own) and, for `auto`/`deny`,
  ## immediately drives the row to a terminal state or to `approved` without
  ## ever prompting the chat UI — `ask` (the default) leaves it
  ## `pending_approval` for the caller to surface an inline approve/deny prompt.
  ##
  ## `auto_workdir` is auto only when every declared path arg resolves under
  ## the conversation's working directory; otherwise it falls back to the
  ## normal `ask` gate (stays `pending_approval`).
  var manifest: ToolManifest
  try:
    manifest = ex.registry.find(toolName)
  except KeyError:
    let id = ex.db.createToolCall(messageId, toolName, argsJson)
    ex.db.setToolCallResult(id, $tcsFailed, failure("unknown tool: " & toolName))
    return id

  let id = ex.db.createToolCall(messageId, toolName, argsJson)
  case ex.effectivePermission(convId, toolName, manifest)
  of ptDeny:
    ex.db.setToolCallResult(id, $tcsDenied, failure("tool is disabled (permission=deny)"))
  of ptAuto:
    let errors = validateArgs(manifest, argsJson)
    if errors.len > 0:
      ex.db.setToolCallResult(id, $tcsValidationFailed, failure(schemaErrorsMsg(errors)))
    else:
      ex.db.setToolCallStatus(id, $tcsApproved)
  of ptAutoWorkdir:
    let wd = ex.workingDirFor(convId)
    if isWithinWorkingDir(wd, manifest.pathArgs.join(","), argsJson):
      let errors = validateArgs(manifest, argsJson)
      if errors.len > 0:
        ex.db.setToolCallResult(id, $tcsValidationFailed, failure(schemaErrorsMsg(errors)))
      else:
        ex.db.setToolCallStatus(id, $tcsApproved)
    ## else: leave pending_approval -> caller prompts the chat UI (fail closed)
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
  ## The tool printed one JSON object
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

proc wakeAfter(ms: int): Future[void] =
  ## `sleepAsync` timers only run when something else wakes httpx's loop (about once a
  ## second); a timerfd-backed timer wakes it on time.
  let fut = newFuture[void]("wakeAfter")
  addTimer(ms, true, proc(fd: AsyncFD): bool {.gcsafe.} =
    fut.complete()
    true)
  fut

proc executeLocally(ex: ToolExecutor, convId, toolCallId: int64, manifest: ToolManifest, argsJson: string) {.async.} =
  ex.db.setToolCallStatus(toolCallId, $tcsRunning)
  ## The subprocess runs with cwd = the conversation's working directory (when
  ## set), so a relative path in a tool argument resolves inside it and the
  ## child sees the canonical value via CERISIER_WORKING_DIR. Empty when unset
  ## (inherits the server's cwd — the old behaviour).
  let p = startLocal(manifest, argsJson, ex.workingDirFor(convId))
  ex.runningProcesses[toolCallId] = p

  let started = getMonoTime()
  const stepMs = 50
  var output = ""
  var killed = false
  var timedOut = false
  while p.running():
    p.drainOutput(output)
    if ex.killRequested.getOrDefault(toolCallId, false):
      p.kill()
      killed = true
      break
    if (getMonoTime() - started).inMilliseconds >= manifest.timeoutMs:
      p.kill()
      timedOut = true
      break
    await wakeAfter(stepMs)

  ex.runningProcesses.del(toolCallId)
  ex.killRequested.del(toolCallId)
  p.drainOutput(output)
  p.close()

  if killed:
    ex.db.setToolCallResult(toolCallId, $tcsKilled, failure("killed by user"))
    return
  if timedOut:
    ex.db.setToolCallResult(toolCallId, $tcsTimeout, failure("timed out after " & $manifest.timeoutMs & "ms"))
    return
  finishWithOutput(ex, toolCallId, manifest, output)

proc execute*(ex: ToolExecutor, convId, toolCallId: int64, toolName, argsJson: string) {.async.} =
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

  await ex.executeLocally(convId, toolCallId, manifest, argsJson)

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
    await askUser(id, toolName, argsJson)
    row = ex.db.getToolCall(id)
  elif row.status == $tcsApproved:
    await ex.execute(convId, id, toolName, argsJson)
    row = ex.db.getToolCall(id)
  DispatchResult(id: id, status: row.status, resultJson: row.resultJson)
