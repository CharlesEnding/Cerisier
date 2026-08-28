## Executes a tool locally (on the server host) via osproc. Always assumes
## the caller has already gone through the approval gate — this module has
## no opinion on approval, it just spawns/drains an already-approved tool
## call.
##
## Spawning and draining are split so the caller (executor.nim) can poll
## `p.running()` in a non-blocking async loop between the two, instead of
## blocking the whole event loop for the tool's entire runtime — that's
## what makes a manual "kill this tool call" request from chat possible.

import std/[osproc, streams, os]
import ../../common/types

proc startLocal*(manifest: ToolManifest, argsJson: string): Process =
  ## `argsJson` is passed as a single CLI argument (the tool is responsible
  ## for parsing it); this keeps the runner generic across nim/python/shell.
  let (cmd, cmdArgs) =
    case manifest.kind
    of tkNimBinary: (manifest.entrypoint, @[argsJson])
    of tkPython: ("python3", @[manifest.entrypoint, argsJson])
    of tkShell: ("/bin/sh", @["-c", manifest.entrypoint & " " & quoteShell(argsJson)])

  startProcess(cmd, args = cmdArgs, options = {poUsePath, poStdErrToStdOut})

proc readAndClose*(p: Process, maxBytes: int = 1_000_000): string =
  ## Drains whatever output the (already-exited, or just-killed) process
  ## produced. Reads in bounded chunks from the output stream rather than
  ## `outputStream.readAll()`'s unbounded slurp, following the same
  ## non-blocking-drain-in-spirit convention used elsewhere in this
  ## codebase (see ../llama/process.nim's `drainAvailableOutput`), capped
  ## so a runaway/huge-output child can never exhaust memory here.
  defer: p.close()
  var output = ""
  let stream = p.outputStream
  var chunk = newString(8192)
  while output.len < maxBytes:
    let n = stream.readData(addr chunk[0], chunk.len)
    if n <= 0:
      break
    output.add(chunk[0 ..< n])
  output

