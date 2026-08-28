## Executes a tool locally (on the server host) via osproc. Always assumes
## the caller has already gone through the approval gate — this module has
## no opinion on approval, it just runs an already-approved tool call.

import std/[osproc, streams, os]
import ../../common/types

type
  ToolRunResult* = object
    exitCode*: int
    output*: string
    timedOut*: bool

proc runLocal*(manifest: ToolManifest, argsJson: string): ToolRunResult =
  ## `argsJson` is passed as a single CLI argument (the tool is responsible
  ## for parsing it); this keeps the runner generic across nim/python/shell.
  let (cmd, cmdArgs) =
    case manifest.kind
    of tkNimBinary: (manifest.entrypoint, @[argsJson])
    of tkPython: ("python3", @[manifest.entrypoint, argsJson])
    of tkShell: ("/bin/sh", @["-c", manifest.entrypoint & " " & quoteShell(argsJson)])

  var p = startProcess(cmd, args = cmdArgs, options = {poUsePath, poStdErrToStdOut})
  defer: p.close()

  let deadline = manifest.timeoutMs
  var waited = 0
  const stepMs = 50
  while p.running() and waited < deadline:
    sleep(stepMs)
    waited += stepMs

  if p.running():
    p.kill()
    return ToolRunResult(exitCode: -1, output: "", timedOut: true)

  let output = p.outputStream.readAll()
  ToolRunResult(exitCode: p.peekExitCode(), output: output, timedOut: false)
