## Tool manifest loading: scans a directory for `*.tool.json` manifests
## describing Nim/Python/shell tools, local or remote.

import std/[json, os, strformat, strutils]
import ../../common/types

proc parsePermission(node: JsonNode): ToolPermission =
  ## `permission: "auto"|"ask"|"deny"` takes precedence; falls back to the
  ## legacy `auto_run: true/false` key (pre-permission-model manifests) for
  ## backward compatibility, defaulting to `ask` otherwise.
  if node.hasKey("permission"):
    try:
      return parseEnum[ToolPermission](node["permission"].getStr("ask"))
    except ValueError:
      return ptAsk
  if node{"auto_run"}.getBool(false):
    return ptAuto
  ptAsk

proc parseManifest(node: JsonNode): ToolManifest =
  ToolManifest(
    name: node{"name"}.getStr(""),
    description: node{"description"}.getStr(""),
    kind: parseEnum[ToolKind](node{"kind"}.getStr("shell")),
    location: parseEnum[ToolLocation](node{"location"}.getStr("local")),
    entrypoint: node{"entrypoint"}.getStr(""),
    inputSchema: $node{"input_schema"},
    outputSchema: $node{"output_schema"},
    timeoutMs: node{"timeout_ms"}.getInt(30_000),
    permission: parsePermission(node),
  )

proc scanToolsDir*(dir: string): seq[ToolManifest] =
  result = @[]
  if not dirExists(dir):
    return
  ## Relative `entrypoint` paths (e.g. "tools/scripts/foo.py") are resolved
  ## against the tools dir's parent so tool scripts run correctly regardless
  ## of the server process's current working directory at launch.
  let root = dir.parentDir()
  for path in walkFiles(dir / "*.tool.json"):
    try:
      let node = parseJson(readFile(path))
      var m = parseManifest(node)
      if m.kind in {tkPython, tkNimBinary} and not m.entrypoint.isAbsolute():
        m.entrypoint = root / m.entrypoint
      result.add(m)
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

proc manifestPath(reg: ToolRegistry, name: string): string =
  reg.dir / (name & ".tool.json")

proc saveManifest*(reg: ToolRegistry, m: ToolManifest) =
  ## Writes/overwrites `<name>.tool.json` and reloads the registry.
  createDir(reg.dir)
  let node = %*{
    "name": m.name,
    "description": m.description,
    "kind": $m.kind,
    "location": $m.location,
    "entrypoint": m.entrypoint,
    "input_schema": (try: parseJson(m.inputSchema) except CatchableError: newJObject()),
    "output_schema": (try: parseJson(m.outputSchema) except CatchableError: newJObject()),
    "timeout_ms": m.timeoutMs,
    "permission": $m.permission,
  }
  writeFile(reg.manifestPath(m.name), node.pretty())
  reg.reload()

proc deleteManifest*(reg: ToolRegistry, name: string) =
  let path = reg.manifestPath(name)
  if fileExists(path):
    removeFile(path)
  reg.reload()

proc find*(reg: ToolRegistry, name: string): ToolManifest =
  for t in reg.tools:
    if t.name == name:
      return t
  raise newException(KeyError, "unknown tool: " & name)

proc systemPromptFragment*(reg: ToolRegistry): string =
  ## Tells the model what tools exist and the exact `<tool_call>` syntax to
  ## use to invoke one. Empty tool list -> empty string (no prompt bloat).
  if reg.tools.len == 0:
    return ""
  var lines: seq[string] = @[]
  lines.add("You have access to the following tools. To call one, emit exactly:")
  lines.add("""<tool_call>{"name": "tool_name", "arguments": {...}}</tool_call>""")
  lines.add("You may emit more than one in a single reply; each will be run and its result given back to you.")
  lines.add("")
  for t in reg.tools:
    let approvalNote = if t.permission == ptAsk: " (requires user approval before it runs)"
                        elif t.permission == ptDeny: " (currently disabled)"
                        else: ""
    lines.add(&"- {t.name}: {t.description}{approvalNote}")
    lines.add(&"  input schema: {t.inputSchema}")
  lines.join("\n")

