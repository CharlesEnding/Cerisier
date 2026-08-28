## Minimal always-on stdout logger. No log levels: every call is printed
## with a timestamp and the emitting component, so the server gives
## verbose output about pages visited, router calls, and tool invocations.

import std/[times]

proc logInfo*(component, msg: string) =
  let ts = now().format("HH:mm:ss")
  echo "[", ts, "] ", component, ": ", msg

proc logWarn*(component, msg: string) =
  let ts = now().format("HH:mm:ss")
  echo "[", ts, "] WARN ", component, ": ", msg

proc logError*(component, msg: string) =
  let ts = now().format("HH:mm:ss")
  echo "[", ts, "] ERROR ", component, ": ", msg
