## Tool manifest loading: scans a directory for `*.tool.json` manifests
## describing Nim/Python/shell tools, local or remote.

import std/[json, os, strutils]
import ../../common/types

proc parseManifest(node: JsonNode): ToolManifest =
  ToolManifest(
    name: node{"name"}.getStr(""),
    description: node{"description"}.getStr(""),
    kind: parseEnum[ToolKind](node{"kind"}.getStr("shell")),
    location: parseEnum[ToolLocation](node{"location"}.getStr("local")),
    entrypoint: node{"entrypoint"}.getStr(""),
    inputSchema: $node{"input_schema"},
    timeoutMs: node{"timeout_ms"}.getInt(30_000),
    autoRun: node{"auto_run"}.getBool(false),
  )

proc scanToolsDir*(dir: string): seq[ToolManifest] =
  result = @[]
  if not dirExists(dir):
    return
  for path in walkFiles(dir / "*.tool.json"):
    try:
      let node = parseJson(readFile(path))
      result.add(parseManifest(node))
    except CatchableError as e:
      stderr.writeLine("cerisier: failed to load tool manifest " & path & ": " & e.msg)

type
  ToolRegistry* = ref object
    dir: string
    tools*: seq[ToolManifest]

proc newToolRegistry*(dir: string): ToolRegistry =
  ToolRegistry(dir: dir, tools: scanToolsDir(dir))

proc reload*(reg: ToolRegistry) =
  reg.tools = scanToolsDir(reg.dir)

proc find*(reg: ToolRegistry, name: string): ToolManifest =
  for t in reg.tools:
    if t.name == name:
      return t
  raise newException(KeyError, "unknown tool: " & name)
