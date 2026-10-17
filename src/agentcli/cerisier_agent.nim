## cerisier-agent: lightweight companion process that runs on the machine
## where the web interface is accessed (the "client"), executing tool calls
## the server dispatches to it and streaming the results back over a
## WebSocket connection.
##
## Protocol (see server/tools/runner_remote.nim and the /ws/agent route):
##   agent -> server  {"type":"hello","name":<host>,"tools":[{"name","description"}]}
##   server -> agent  {"type":"run_tool","id":<job>,"tool":<name>,"args":<json string>}
##   agent -> server  {"type":"tool_result","id":<job>,"exit_code":<int>,"output":<stdout+stderr>}
##   server -> agent  {"type":"kill_tool","id":<job>}
##
## The agent loads its own tool manifests from --tools-dir (the same
## `*.tool.json` format the server uses) and only runs tools it has itself:
## the server never sends code, only a tool name and arguments.
##
## Usage:   cerisier-agent --server-url=ws://SERVER:8888/ws/agent --tools-dir=tools [--name=laptop]
## Build:   nim c -d:release src/agent/cerisier_agent.nim      (add -d:ssl for wss://)
## Needs the `ws` nimble package (already a dependency of Prologue).

import std/[json, os, parseopt, osproc, asyncdispatch, strutils, tables]
import ws
import ../server/tools/registry
import ../server/tools/runner_local

type
  AgentOptions = object
    serverUrl: string
    toolsDir: string
    name: string

  AgentState = ref object
    kills: Table[string, bool] ## job id -> kill requested
    backoffMs: int

proc parseArgs(): AgentOptions =
  result = AgentOptions(
    serverUrl: "ws://127.0.0.1:8888/ws/agent",
    toolsDir: "tools",
    name: getEnv("HOSTNAME", getEnv("COMPUTERNAME", "agent")))
  var p = initOptParser()
  for kind, key, val in p.getopt():
    if kind == cmdLongOption:
      case key
      of "server-url": result.serverUrl = val
      of "tools-dir": result.toolsDir = val
      of "name": result.name = val
      else: discard

proc helloMessage(opts: AgentOptions, reg: ToolRegistry): string =
  var arr = newJArray()
  for t in reg.tools:
    arr.add(%*{"name": t.name, "description": t.description})
  $(%*{"type": "hello", "name": opts.name, "tools": arr})

proc runJob(ws: WebSocket, st: AgentState, reg: ToolRegistry,
            jobId, toolName, argsJson: string) {.async.} =
  ## Runs one tool call and sends its result. Never raises: every failure is
  ## reported back as a result so the server isn't left waiting.
  var exitCode = -1
  var output = ""
  try:
    let manifest = reg.find(toolName)
    let p = startLocal(manifest, argsJson)
    var waited = 0
    const stepMs = 50
    var stopped = ""
    while p.running():
      if st.kills.getOrDefault(jobId, false):
        p.kill()
        stopped = "killed"
        break
      if waited >= manifest.timeoutMs:
        p.kill()
        stopped = "timed out"
        break
      await sleepAsync(stepMs)
      waited += stepMs
    if stopped.len > 0:
      output = stopped
      discard readAndClose(p)
    else:
      exitCode = p.peekExitCode()
      output = readAndClose(p)
  except CatchableError as e:
    output = "error: " & e.msg
  st.kills.del(jobId)
  try:
    await ws.send($(%*{"type": "tool_result", "id": jobId, "exit_code": exitCode, "output": output}))
  except CatchableError:
    discard ## connection dropped while the tool was running

proc runSession(opts: AgentOptions, st: AgentState, reg: ToolRegistry) {.async.} =
  let ws = await newWebSocket(opts.serverUrl)
  st.backoffMs = 1000 ## connected: the next failure starts the backoff over
  echo "cerisier-agent: connected to ", opts.serverUrl
  await ws.send(helloMessage(opts, reg))
  while ws.readyState == Open:
    let packet = await ws.receiveStrPacket()
    let node = parseJson(packet)
    case node{"type"}.getStr("")
    of "run_tool":
      asyncCheck runJob(ws, st, reg, node{"id"}.getStr(""), node{"tool"}.getStr(""),
                        node{"args"}.getStr("{}"))
    of "kill_tool":
      st.kills[node{"id"}.getStr("")] = true
    else:
      discard

proc agentMain(opts: AgentOptions) {.async.} =
  let st = AgentState(kills: initTable[string, bool](), backoffMs: 1000)
  while true:
    let reg = newToolRegistry(opts.toolsDir) ## re-scanned on every (re)connect
    echo "cerisier-agent: ", reg.tools.len, " local tool(s) found in ", opts.toolsDir
    try:
      await runSession(opts, st, reg)
      echo "cerisier-agent: server closed the connection"
    except CatchableError as e:
      echo "cerisier-agent: connection problem: ", e.msg
    echo "cerisier-agent: reconnecting in ", st.backoffMs div 1000, "s"
    await sleepAsync(st.backoffMs)
    st.backoffMs = min(st.backoffMs * 2, 15000)

when isMainModule:
  waitFor agentMain(parseArgs())
