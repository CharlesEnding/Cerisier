## Executes a tool on a remote `cerisier-agent` companion process, over
## the WebSocket channel it maintains with the server. This module defines
## the message protocol and a simple in-memory registry of connected
## companions; the actual WebSocket transport wiring lives in the server's
## web layer (routes/websocket.nim) which calls into this module.

import std/[json, tables, options, oids, asyncdispatch]
import ../../common/types

type
  CompanionId* = string

  CompanionSender* = proc(msg: string): Future[void] {.gcsafe.}
    ## Writes one text frame to a connected agent's WebSocket (a closure
    ## created by the /ws/agent route; this module never touches sockets).

  PendingJob* = object
    id*: string
    toolName*: string
    argsJson*: string

  RemoteJobResult* = object
    exitCode*: int
    output*: string

  CompanionRegistry* = ref object
    ## Maps companion id -> its advertised tool manifests.
    companions*: Table[CompanionId, seq[ToolManifest]]
    senders*: Table[CompanionId, CompanionSender]
    names*: Table[CompanionId, string]   ## human-readable agent names (hostnames)
    ## Pending jobs awaiting a result from a companion, keyed by job id.
    pending*: Table[string, RemoteJobResult]

proc newCompanionRegistry*(): CompanionRegistry =
  CompanionRegistry(companions: initTable[CompanionId, seq[ToolManifest]](),
                     senders: initTable[CompanionId, CompanionSender](),
                     names: initTable[CompanionId, string](),
                     pending: initTable[string, RemoteJobResult]())

proc register*(reg: CompanionRegistry, id: CompanionId, tools: seq[ToolManifest]) =
  reg.companions[id] = tools

proc registerSender*(reg: CompanionRegistry, id: CompanionId, sender: CompanionSender) =
  reg.senders[id] = sender

proc unregister*(reg: CompanionRegistry, id: CompanionId) =
  reg.companions.del(id)
  reg.senders.del(id)
  reg.names.del(id)

proc connectedCount*(reg: CompanionRegistry): int =
  reg.companions.len

proc sendTo*(reg: CompanionRegistry, id: CompanionId, msg: string): Future[void] {.async.} =
  if not reg.senders.hasKey(id):
    raise newException(IOError, "client agent is not connected")
  await reg.senders[id](msg)

proc findCompanionFor*(reg: CompanionRegistry, toolName: string): Option[CompanionId] =
  for id, tools in reg.companions:
    for t in tools:
      if t.name == toolName:
        return some(id)
  none(CompanionId)

proc makeJob*(toolName, argsJson: string): PendingJob =
  PendingJob(id: $genOid(), toolName: toolName, argsJson: argsJson)

proc toWire*(job: PendingJob): string =
  $(%*{"type": "run_tool", "id": job.id, "tool": job.toolName, "args": job.argsJson})

proc parseResult*(msg: string): (string, RemoteJobResult) =
  let node = parseJson(msg)
  let id = node{"id"}.getStr("")
  let res = RemoteJobResult(
    exitCode: node{"exit_code"}.getInt(-1),
    output: node{"output"}.getStr(""),
  )
  (id, res)

proc submitResult*(reg: CompanionRegistry, jobId: string, res: RemoteJobResult) =
  reg.pending[jobId] = res

proc takeResult*(reg: CompanionRegistry, jobId: string): Option[RemoteJobResult] =
  if reg.pending.hasKey(jobId):
    result = some(reg.pending[jobId])
    reg.pending.del(jobId)
  else:
    result = none(RemoteJobResult)
