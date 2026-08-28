## cerisier-agent: lightweight companion process that runs on the machine
## where the web interface is accessed, executing "local" tools on the
## user's behalf and streaming results back to cerisier-server over a
## WebSocket connection.

import std/[json, os, parseopt, osproc]
import ../server/tools/registry
import ../server/tools/runner_local

type
  AgentOptions = object
    serverUrl: string
    toolsDir: string

proc parseArgs(): AgentOptions =
  result = AgentOptions(serverUrl: "ws://127.0.0.1:8888/ws/agent", toolsDir: "tools")
  var p = initOptParser()
  for kind, key, val in p.getopt():
    if kind == cmdLongOption:
      case key
      of "server-url": result.serverUrl = val
      of "tools-dir": result.toolsDir = val

proc handleJob(reg: ToolRegistry, jobJson: JsonNode): JsonNode =
  let toolName = jobJson{"tool"}.getStr("")
  let argsJson = jobJson{"args"}.getStr("{}")
  let jobId = jobJson{"id"}.getStr("")
  try:
    let manifest = reg.find(toolName)
    let p = startLocal(manifest, argsJson)
    var waited = 0
    const stepMs = 50
    while p.running() and waited < manifest.timeoutMs:
      sleep(stepMs)
      waited += stepMs
    if p.running():
      p.kill()
      return %*{"id": jobId, "exit_code": -1, "output": "timed out"}
    let exitCode = p.peekExitCode()
    let output = readAndClose(p)
    %*{"id": jobId, "exit_code": exitCode, "output": output}
  except CatchableError as e:
    %*{"id": jobId, "exit_code": -1, "output": "error: " & e.msg}

when isMainModule:
  let opts = parseArgs()
  let reg = newToolRegistry(opts.toolsDir)
  echo "cerisier-agent: ", reg.tools.len, " local tool(s) found in ", opts.toolsDir
  echo "cerisier-agent: would connect to ", opts.serverUrl,
       " (WebSocket client wiring is left for the runtime environment where a server is reachable)"
  ## NOTE: the actual persistent WebSocket connection loop (connect, send tool
  ## advertisement, receive `run_tool` jobs, call handleJob, send results) is
  ## intentionally not opened here since there is no server/network to
  ## connect to on this dev machine; `handleJob` above is the unit that a
  ## real connection loop would invoke per incoming job.
