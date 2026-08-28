## Orchestrates a single tool call through its lifecycle:
## pending_approval -> approved -> running -> succeeded/failed/timeout/denied.
## The approval UI must be given the full tool name + exact argsJson so the
## user can see precisely what will run before approving (mandatory, no
## bypass beyond a tool's opt-in `autoRun` flag).

import std/[options]
import ../db/database
import ../../common/types
import ./registry
import ./runner_local
import ./runner_remote

type
  ToolExecutor* = ref object
    db: Database
    registry: ToolRegistry
    companions: CompanionRegistry

proc newToolExecutor*(db: Database, registry: ToolRegistry, companions: CompanionRegistry): ToolExecutor =
  ToolExecutor(db: db, registry: registry, companions: companions)

proc requestToolCall*(ex: ToolExecutor, messageId: int64, toolName, argsJson: string): int64 =
  ## Always creates a pending_approval row (or auto-approves if the tool
  ## manifest opts into autoRun) — the caller must poll/approve via the UI.
  let manifest = ex.registry.find(toolName)
  let id = ex.db.createToolCall(messageId, toolName, $manifest.location, argsJson)
  if manifest.autoRun:
    ex.db.setToolCallStatus(id, "approved")
  id

proc approve*(ex: ToolExecutor, toolCallId: int64) =
  ex.db.setToolCallStatus(toolCallId, "approved")

proc deny*(ex: ToolExecutor, toolCallId: int64) =
  ex.db.setToolCallStatus(toolCallId, "denied")

proc execute*(ex: ToolExecutor, toolCallId: int64, toolName, argsJson, location: string) =
  ## Runs an already-approved tool call synchronously and records the result.
  ex.db.setToolCallStatus(toolCallId, "running")
  let manifest = ex.registry.find(toolName)
  case manifest.location
  of tlLocal:
    let res = runLocal(manifest, argsJson)
    let status = if res.timedOut: "timeout" elif res.exitCode == 0: "succeeded" else: "failed"
    ex.db.setToolCallResult(toolCallId, status, res.output)
  of tlRemote:
    let companion = ex.companions.findCompanionFor(toolName)
    if companion.isNone:
      ex.db.setToolCallResult(toolCallId, "failed", "no companion agent connected for this tool")
    else:
      # Actual dispatch over the WebSocket happens in the web layer, which
      # calls submitResult/takeResult on the shared CompanionRegistry; this
      # proc only marks the intent so the caller can await it there.
      discard
