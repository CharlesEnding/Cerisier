## Host description for the system prompt ({{system}}): OS, CPU, RAM, free disk
## and the versions of common programs. The slow, unchanging part (program
## versions) is probed once by `initSystemInfo`, which must run before the
## server starts accepting requests because it blocks. RAM and disk are read on
## every call.

import std/[strutils, os, osproc, posix]

const probes: seq[(string, string)] = @[
  ("git", "--version"), ("python3", "--version"), ("pip3", "--version"),
  ("node", "--version"), ("npm", "--version"), ("nim", "--version"),
  ("nimble", "--version"), ("gcc", "--version"), ("make", "--version"),
  ("cargo", "--version"), ("go", "version"), ("docker", "--version"),
  ("ffmpeg", "-version"), ("convert", "-version"), ("pdftotext", "-v"),
  ("sqlite3", "--version"), ("curl", "--version"), ("rg", "--version"),
  ("jq", "--version"), ("pandoc", "--version"), ("tesseract", "--version")]

var
  programsLine = ""
  osLine = ""
  cpuLine = ""

proc firstVersion(s: string): string =
  ## First dotted number in `s` (e.g. "3.12.3"), or "" if none.
  var i = 0
  while i < s.len:
    if s[i] in Digits:
      var j = i
      while j < s.len and s[j] in Digits + {'.'}:
        inc j
      let tok = s[i ..< j].strip(chars = {'.'})
      if '.' in tok:
        return tok
      i = j
    else:
      inc i
  ""

proc readKeyed(path, key: string): string =
  ## Value of a `KEY=value` or `key : value` line, quotes stripped.
  if not fileExists(path):
    return ""
  for line in lines(path):
    if line.startsWith(key):
      let rest = line[key.len .. ^1].strip(chars = {' ', '\t', '=', ':', '"'})
      return rest
  ""

proc initSystemInfo*() =
  var found: seq[string]
  for (prog, arg) in probes:
    if findExe(prog).len == 0:
      continue
    try:
      let (outp, code) = execCmdEx(prog & " " & arg)
      let v = firstVersion(outp.splitLines()[0])
      if code == 0 and v.len > 0:
        found.add(prog & " " & v)
      elif code == 0:
        found.add(prog)
    except CatchableError:
      found.add(prog)
  programsLine = found.join(", ")

  osLine = readKeyed("/etc/os-release", "PRETTY_NAME")
  let model = readKeyed("/proc/cpuinfo", "model name")
  cpuLine = model & " (" & $countProcessors() & " threads)"

proc memMb(key: string): int =
  let v = readKeyed("/proc/meminfo", key).split(' ')[0]
  try: parseInt(v) div 1024 except ValueError: 0

proc freeGb(path: string): string =
  var s: Statvfs
  if statvfs(path.cstring, s) != 0:
    return "unknown"
  let bytes = s.f_bavail.int64 * s.f_frsize.int64
  formatFloat(bytes.float / 1073741824.0, ffDecimal, 1) & " GB"

proc systemInfoText*(workingDir: string): string =
  {.cast(gcsafe).}:
    var lines = @["## Host machine"]
    if osLine.len > 0:
      lines.add("- OS: " & osLine)
    if cpuLine.strip().len > 0:
      lines.add("- CPU: " & cpuLine)
    lines.add("- User home directory: " & getHomeDir().strip(leading = false, chars = {'/'}))
    lines.add("- RAM: " & $memMb("MemTotal") & " MB total, " & $memMb("MemAvailable") & " MB available")
    lines.add("- Free disk space: " & freeGb("/") & " on /")
    if workingDir.len > 0 and dirExists(workingDir):
      lines.add("  and " & freeGb(workingDir) & " where the working directory is")
    if programsLine.len > 0:
      lines.add("- Installed programs: " & programsLine)
    result = lines.join("\n")
