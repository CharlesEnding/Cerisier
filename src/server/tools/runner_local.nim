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

proc startLocal*(manifest: ToolManifest, argsJson: string, cwd: string = ""): Process =
  ## `argsJson` is passed as a single CLI argument (the tool is responsible
  ## for parsing it); this keeps the runner generic across nim/python/shell.
  ##
  ## `cwd` (when non-empty) is set as the process's working directory and is
  ## also exported as `CERISIER_WORKING_DIR`. The harness passes the
  ## conversation's stored working directory here so a relative path in a
  ## tool argument resolves inside it by construction, and a tool can read
  ## the canonical value from the environment rather than trusting something
  ## the model wrote into its own args. When `cwd` is empty we leave the
  ## environment untouched (pass `[]`) so the child inherits the server's
  ## environment exactly as before — no working directory set means no change
  ## to the old behaviour.
  let (cmd, cmdArgs) =
    case manifest.kind
    of tkNimBinary: (manifest.entrypoint, @[argsJson])
    of tkPython: ("python3", @[manifest.entrypoint, argsJson])
    of tkShell: ("/bin/sh", @["-c", manifest.entrypoint & " " & quoteShell(argsJson)])

  ## `dir = cwd` makes the child run inside the conversation's working directory
  ## (when set), so a relative path in a tool argument resolves there by
  ## construction, and the child can read it via os.getcwd(). The harness sets
  ## this, never the model, so the model can't steer it by lying about a path.
  ## When cwd is "" (unset) we pass the empty env/dir defaults so the child
  ## inherits the server's environment and working directory exactly as before.
  startProcess(cmd, args = cmdArgs, workingDir = cwd, options = {poUsePath, poStdErrToStdOut})

proc readAndClose*(p: Process, maxBytes: int = 1_000_000): string =
  ## Drains whatever output the (already-exited, or just-killed) process
  ## produced. Reads in bounded chunks from the output stream rather than
  ## `outputStream.readAll()`'s unbounded slurp, capped
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

