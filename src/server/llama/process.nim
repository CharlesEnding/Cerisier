## Supervises the single `llama-server` router-mode process.
##
## We deliberately do NOT spawn one process per model: llama-server's
## router mode (started without `-m`) already loads/unloads/hot-swaps models
## via its own HTTP API. This module only owns the lifecycle of that one
## router process: start, health-check, crash-restart with backoff, stop.

import std/[osproc, options, times, os, strutils, streams]
import ../config
import ../log

const maxOutputLines = 200
const crashReasonNeedles = [
  "out of memory", "failed to allocate", "cudamalloc", "insufficient memory",
  "cuda error", "ggml_backend", "cannot allocate memory", "oom",
]

type
  ProcessState* = enum
    psStopped
    psStarting
    psRunning
    psCrashed

  ProcessManager* = ref object
    cfg: Config
    process: Option[Process]
    state*: ProcessState
    restartCount*: int
    lastExitCode*: int
    lastCrashReason*: string
    logFile: string
    outputLines: seq[string] ## bounded ring buffer of the router's recent stdout/stderr

proc newProcessManager*(cfg: Config): ProcessManager =
  ProcessManager(
    cfg: cfg,
    process: none(Process),
    state: psStopped,
    restartCount: 0,
    lastExitCode: 0,
    lastCrashReason: "",
    logFile: cfg.dataDir / "llama-router.log",
    outputLines: @[],
  )

proc routerArgs(cfg: Config): seq[string] =
  ## No `-m` on purpose: this launches llama-server in router mode.
  ## Deliberately NOT passing `--models-dir`: our generated `--models-preset`
  ## ini already lists every model under `modelsDir` (configured presets
  ## plus placeholder entries for anything newly discovered — see
  ## `ensurePresetsFile`/`discoverUnconfiguredModels`). Passing both flags
  ## makes llama-server additionally auto-scan `modelsDir` itself and
  ## register each model a second time under its raw folder name, which is
  ## why `/models` used to show duplicate entries differing only in case.
  result = @[
    "--host", cfg.llamaHost,
    "--port", $cfg.llamaPort,
  ]
  if fileExists(cfg.presetsPath):
    result.add(["--models-preset", cfg.presetsPath])


proc isAlive*(pm: ProcessManager): bool =
  pm.process.isSome and pm.process.get().running()

proc appendOutputLine(pm: ProcessManager, line: string) =
  pm.outputLines.add(line)
  if pm.outputLines.len > maxOutputLines:
    pm.outputLines.delete(0)
  try:
    let f = open(pm.logFile, fmAppend)
    defer: f.close()
    f.writeLine(line)
  except IOError:
    discard

proc drainOutput*(pm: ProcessManager, maxLines: int = 50) =
  ## Best-effort drain of the router process's merged stdout/stderr into
  ## `outputLines` (ring buffer, most recent `maxOutputLines`) and
  ## `logFile`, so a crash's last log lines are available for
  ## `pollAndRestartIfCrashed` to scan for a reason (e.g. an OOM message)
  ## and so `logFile` can be tailed directly. Bounded to `maxLines` per call
  ## so a burst of output can't stall the caller for long; `atEnd()` on a
  ## pipe stream can itself block briefly waiting for data, which is an
  ## accepted tradeoff here (there's no live router on this dev machine to
  ## validate against real output volume/timing).
  if pm.process.isNone:
    return
  let p = pm.process.get()
  let outStream = p.outputStream
  var count = 0
  while count < maxLines and not outStream.atEnd():
    let line = outStream.readLine()
    appendOutputLine(pm, line)
    inc count

proc detectCrashReason(pm: ProcessManager): string =
  ## Scans the most recent captured output lines for known OOM/failure
  ## substrings. Falls back to a generic message with the exit code if
  ## nothing recognizable was seen (e.g. output wasn't drained in time).
  for i in countdown(pm.outputLines.len - 1, max(0, pm.outputLines.len - 40)):
    let lower = pm.outputLines[i].toLowerAscii()
    for needle in crashReasonNeedles:
      if lower.contains(needle):
        return pm.outputLines[i]
  "unknown (exit code " & $pm.lastExitCode & ")"

proc start*(pm: ProcessManager) =
  if pm.isAlive():
    return
  pm.state = psStarting
  let args = routerArgs(pm.cfg)
  let p = startProcess(
    pm.cfg.llamaServerBin,
    args = args,
    options = {poStdErrToStdOut, poUsePath}
  )
  pm.process = some(p)
  pm.state = psRunning

proc stop*(pm: ProcessManager, killTimeoutMs: int = 5000) =
  if not pm.isAlive():
    pm.state = psStopped
    return
  var p = pm.process.get()
  try:
    p.terminate() # SIGTERM
  except OSError:
    discard
  let deadline = epochTime() + (killTimeoutMs.float / 1000.0)
  while p.running() and epochTime() < deadline:
    sleep(100)
  if p.running():
    p.kill() # SIGKILL
  pm.lastExitCode = p.peekExitCode()
  p.close()
  pm.process = none(Process)
  pm.state = psStopped

proc pollAndRestartIfCrashed*(pm: ProcessManager, maxRestarts: int = 5): bool =
  ## Call periodically from the server's event loop. Returns true if a
  ## restart was performed.
  if pm.process.isNone:
    return false
  var p = pm.process.get()
  if p.running():
    return false
  # process exited unexpectedly
  pm.lastExitCode = p.peekExitCode()
  p.close()
  pm.process = none(Process)
  pm.state = psCrashed
  pm.lastCrashReason = detectCrashReason(pm)
  logError("process", "router process exited unexpectedly (exit code " & $pm.lastExitCode &
    "), likely reason: " & pm.lastCrashReason)
  if pm.restartCount >= maxRestarts:
    logError("process", "router crashed " & $pm.restartCount & " time(s); giving up on auto-restart, manual intervention needed")
    return false
  inc pm.restartCount
  logWarn("process", "restarting router (attempt " & $pm.restartCount & "/" & $maxRestarts & ")")
  # simple linear backoff
  sleep(min(pm.restartCount, 10) * 500)
  pm.start()
  return true
