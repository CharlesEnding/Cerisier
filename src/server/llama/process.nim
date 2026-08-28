## Supervises the single `llama-server` router-mode process.
##
## We deliberately do NOT spawn one process per model: llama-server's
## router mode (started without `-m`) already loads/unloads/hot-swaps models
## via its own HTTP API. This module only owns the lifecycle of that one
## router process: start, health-check, crash-restart with backoff, stop.

import std/[osproc, options, times, os, strutils, posix]
import ../config
import ../log

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
    logFile*: string ## captured router/child stdout, see `start`/`drainAvailableOutput`
    pendingOutputBuf: string ## partial (not-yet-newline-terminated) data between drainAvailableOutput calls

proc newProcessManager*(cfg: Config): ProcessManager =
  result = ProcessManager(
    cfg: cfg,
    process: none(Process),
    state: psStopped,
    restartCount: 0,
    lastExitCode: 0,
    lastCrashReason: "",
    logFile: cfg.dataDir / "llama-router.log",
    pendingOutputBuf: "",
  )
  # Truncate any leftover content from a previous app run: this file used
  # to accumulate forever across separate app launches, which repeatedly
  # caused old stale output (from a since-replaced binary/config) to look
  # exactly like current output and waste everyone's time. Restarts of the
  # router process *within* this one app run still append normally (see
  # `pollAndRestartIfCrashed`/`start`), so crash history across those is
  # preserved — only a brand new app process gets a clean slate.
  try:
    let f = open(result.logFile, fmWrite)
    f.close()
  except IOError:
    discard

proc routerArgs(cfg: Config): seq[string] =
  ## No `-m` on purpose: this launches llama-server in router mode.
  ## Deliberately NOT passing `--models-dir`: our generated `--models-preset`
  ## ini already lists every model under `modelsDir` (configured presets
  ## plus placeholder entries for anything newly discovered — see
  ## `ensurePresetsFile`/`discoverUnconfiguredModels`). Passing both flags
  ## makes llama-server additionally auto-scan `modelsDir` itself and
  ## register each model a second time under its raw folder name, which is
  ## why `/models` used to show duplicate entries differing only in case.
  ##
  ## Deliberately NOT passing `--log-file`: it was tried, and looked like it
  ## worked once (a crash dumped a full, rich log) but then went silent for
  ## every load after that. Root cause: on a real terminal, stdout is a TTY
  ## and glibc auto-line-buffers, so `llama-server` run by hand looks
  ## instant/rich. Piped to us (not a TTY, and `--log-file`'s FILE* on a
  ## regular file is the same story), stdio defaults to FULLY buffered —
  ## nothing gets written until the internal buffer fills or the process
  ## exits. That's exactly why only a crash (which forces a flush at exit)
  ## ever produced content, and normal/successful loads produced nothing.
  ## Fix: go back to piping stdout/stderr (already merged via
  ## `poStdErrToStdOut`) and force *line buffering* on it externally via
  ## `stdbuf` in `start()`, so `drainAvailableOutput` actually sees lines as
  ## they're produced.
  ##
  ## Deliberately NOT passing `--verbose`: that sets llama.cpp's log level
  ## to full DEBUG, which emits a `create_tensor: loading tensor ...` line
  ## for literally every tensor in the model (tens of thousands of lines
  ## for a large model). That firehose completely buries the actually
  ## useful INFO/WARN/ERROR lines (load progress, HTTP request logs, OOM
  ## errors) outside our tail window, which is why the /router page looked
  ## frozen/useless — it was 100% debug spam from one load, not "nothing
  ## happening". The default log level already includes load
  ## start/success/failure and error messages without the tensor-by-tensor
  ## noise.
  result = @[
    "--host", cfg.llamaHost,
    "--port", $cfg.llamaPort,
  ]
  if fileExists(cfg.presetsPath):
    result.add(["--models-preset", cfg.presetsPath])


proc isAlive*(pm: ProcessManager): bool =
  pm.process.isSome and pm.process.get().running()

proc appendToLogFile(pm: ProcessManager, line: string) =
  try:
    let f = open(pm.logFile, fmAppend)
    defer: f.close()
    f.writeLine(line)
  except IOError:
    discard

proc logAppend*(pm: ProcessManager, line: string) =
  ## Lets callers outside this module (routes.nim) record their own events
  ## — e.g. "load requested"/"load result" — directly into the same log
  ## file the /router page displays. This exists because llama-server's own
  ## logging has repeatedly been shown to NOT mention every load attempt
  ## (e.g. a request it rejects/handles without ever spawning or logging
  ## anything), which made it look like requests were vanishing into a
  ## void. Recording our own side of every request/response guarantees an
  ## attempt can never be silently absent from the log again, regardless
  ## of what llama-server chooses to log internally.
  appendToLogFile(pm, "[cerisier] " & line)

proc drainAvailableOutput*(pm: ProcessManager, maxLines: int = 1000) =
  ## Reads whatever the router has printed to its own stdout/stderr
  ## (merged via `poStdErrToStdOut`) since the last call, and appends
  ## complete lines into `logFile` tagged `[stdout]`.
  ##
  ## Does a raw non-blocking `read(2)` on the pipe's fd instead of using
  ## `osproc.hasData()`/`Stream.atEnd()`. Reading Nim's own osproc.nim
  ## source confirmed `hasData()` calls POSIX `select()` with a NULL
  ## timeout, i.e. it **blocks indefinitely** until data arrives — not the
  ## non-blocking peek its name implies. Calling that from this
  ## periodically-scheduled async proc silently froze the entire
  ## single-threaded reactor (this app's own HTTP handling included)
  ## waiting for the router's next byte of output, which during a normal
  ## (non-crashing) run could be a very long time or never. That is the
  ## actual reason nothing but our own `[cerisier]` lines ever showed up
  ## here — we were stuck blocked inside `hasData()`, not "no data was
  ## available". Setting `O_NONBLOCK` on the fd and calling `read(2)`
  ## directly returns immediately either way (data, EOF, or EAGAIN), so
  ## this can never stall the reactor.
  if pm.process.isNone:
    return
  let p = pm.process.get()
  let fd = cint(p.outputHandle)
  let flags = fcntl(fd, F_GETFL, 0)
  discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)
  var buf = newString(8192)
  var lineCount = 0
  while lineCount < maxLines:
    let n = read(fd, addr buf[0], buf.len)
    if n > 0:
      pm.pendingOutputBuf.add(buf[0 ..< n])
      var idx = pm.pendingOutputBuf.find('\n')
      while idx >= 0:
        let line = pm.pendingOutputBuf[0 ..< idx].strip(leading = false, chars = {'\r'})
        pm.pendingOutputBuf = pm.pendingOutputBuf[idx + 1 .. ^1]
        appendToLogFile(pm, "[stdout] " & line)
        inc lineCount
        idx = pm.pendingOutputBuf.find('\n')
    else:
      # n == 0: EOF (process closed its output). n < 0: EAGAIN/EWOULDBLOCK
      # (no more data available right now, the expected non-blocking case)
      # or some other read error — either way, nothing more to drain now.
      break


proc logFileStats*(pm: ProcessManager): tuple[exists: bool, sizeBytes: int64, lastModified: string] =
  ## Exposed on the /router page so it's immediately obvious whether the
  ## log is actually still being written to (size/mtime advancing) versus
  ## silently stale, instead of just staring at possibly-unchanged text.
  if not fileExists(pm.logFile):
    return (false, 0'i64, "")
  try:
    let info = getFileInfo(pm.logFile)
    (true, info.size, $info.lastWriteTime)
  except OSError:
    (fileExists(pm.logFile), 0'i64, "")

proc recentOutput*(pm: ProcessManager, maxLines: int = 0): seq[string] =
  ## Lines of the router's own log file, for diagnostics display (e.g. the
  ## /router status page). Re-reads the file fresh every call, so this is
  ## always up to date and works whether the process is alive, crashed, or
  ## not started yet (missing file -> empty result). `maxLines = 0` (the
  ## default) returns the *entire* file — the whole point of a log page is
  ## to show the log, not an arbitrarily truncated slice of it. Pass a
  ## positive `maxLines` only for callers that specifically want a tail
  ## (e.g. crash-reason scanning).
  result = @[]
  if not fileExists(pm.logFile):
    return
  try:
    let allLines = readFile(pm.logFile).splitLines()
    let lines = if allLines.len > 0 and allLines[^1].len == 0: allLines[0 ..< ^1] else: allLines
    if maxLines <= 0 or lines.len <= maxLines:
      result = lines
    else:
      result = lines[lines.len - maxLines .. ^1]
  except IOError:
    discard

proc detectCrashReason(pm: ProcessManager): string =
  ## Scans the most recent lines of the router's log file for known
  ## OOM/failure substrings. Falls back to a generic message with the exit
  ## code if nothing recognizable was seen.
  let lines = pm.recentOutput(200)
  for i in countdown(lines.len - 1, 0):
    let lower = lines[i].toLowerAscii()
    for needle in crashReasonNeedles:
      if lower.contains(needle):
        return lines[i]
  "unknown (exit code " & $pm.lastExitCode & ")"

proc start*(pm: ProcessManager) =
  if pm.isAlive():
    return
  pm.state = psStarting
  let args = routerArgs(pm.cfg)
  # `stdbuf -oL -eL`: forces line-buffering on the child's stdout/stderr
  # instead of the fully-buffered-by-default behavior a non-TTY pipe gets,
  # so `drainAvailableOutput` sees lines as they're produced instead of
  # only in one big dump when the process eventually exits/crashes. Falls
  # back to launching directly (old fully-buffered behavior) if `stdbuf`
  # isn't installed, rather than failing to start the router at all.
  let stdbufPath = findExe("stdbuf")
  let p =
    if stdbufPath.len > 0:
      startProcess(
        stdbufPath,
        args = @["-oL", "-eL", pm.cfg.llamaServerBin] & args,
        options = {poStdErrToStdOut, poUsePath}
      )
    else:
      startProcess(
        pm.cfg.llamaServerBin,
        args = args,
        options = {poStdErrToStdOut, poUsePath}
      )
  pm.process = some(p)
  pm.pendingOutputBuf = "" # discard any unterminated line left over from a previous process
  pm.state = psRunning
  appendToLogFile(pm, "[cerisier] router process started, pid=" & $p.processID & " bin=" & pm.cfg.llamaServerBin & " args=" & $args)

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
