## Supervises the single `llama-server` router-mode process.
##
## We deliberately do NOT spawn one process per model: llama-server's
## router mode (started without `-m`) already loads/unloads/hot-swaps models
## via its own HTTP API. This module only owns the lifecycle of that one
## router process: start, health-check, crash-restart with backoff, stop.

import std/[osproc, options, times, os]
import ../config

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
    logFile: string

proc newProcessManager*(cfg: Config): ProcessManager =
  ProcessManager(
    cfg: cfg,
    process: none(Process),
    state: psStopped,
    restartCount: 0,
    lastExitCode: 0,
    logFile: cfg.dataDir / "llama-router.log",
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
  if pm.restartCount >= maxRestarts:
    return false
  inc pm.restartCount
  # simple linear backoff
  sleep(min(pm.restartCount, 10) * 500)
  pm.start()
  return true
