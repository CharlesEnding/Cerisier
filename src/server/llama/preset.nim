## Generates and maintains the `models-preset.ini` file consumed by
## llama-server's router mode (`--models-preset`). Each preset section maps
## to a model the user has locally; keys mirror llama-server CLI flags
## without their leading dashes (see llama.cpp server docs).

import std/[os, strformat, sequtils, strutils]
import ../log

type
  ModelPreset* = object
    id*: string                 ## section name, e.g. "qwen3.8-27b-unc"
    modelPath*: string
    mmprojPath*: string         ## empty if the model has no vision projector
    ctxSize*: int
    nGpuLayers*: string         ## "999", "auto", "all", ...
    chatTemplateKwargs*: string ## raw JSON string, e.g. {"reasoning_effort":"medium"}
    temperature*: float
    topP*: float
    topK*: int
    minP*: float
    presencePenalty*: float
    loadOnStartup*: bool

proc defaultPresets*(): seq[ModelPreset] =
  ## Seeded from the models referenced in the original start-llama.sh.
  @[
    ModelPreset(
      id: "qwen3.8-27b-unc",
      modelPath: "/home/christian/models/Qwen3.8-27B-UNC/Qwen3.8-27B-Uncensored-Q5_K_M.gguf",
      mmprojPath: "",
      ctxSize: 65536,
      nGpuLayers: "999",
      chatTemplateKwargs: """{"reasoning_effort":"medium"}""",
      temperature: 1.0,
      topP: 0.95,
      topK: 20,
      minP: 0.0,
      presencePenalty: 0.0,
      loadOnStartup: true,
    )
  ]

proc idFromPath(path: string): string =
  splitFile(path).name.toLowerAscii().replace(" ", "-").replace("_", "-")

proc isMmprojName(name: string): bool =
  let n = name.toLowerAscii()
  n.contains("mmproj") or n.contains("vision") or n.contains("clip")

proc findModelGgufsInFolder(folder: string): tuple[modelPath: string, mmprojPath: string] =
  ## Within a single model folder, picks the primary (largest, non-mmproj)
  ## `.gguf` as the model and, if present, a mmproj/vision-projector `.gguf`
  ## as the optional companion.
  var bestPath = ""
  var bestSize: BiggestInt = -1
  var mmprojPath = ""
  for path in walkDirRec(folder):
    if not path.toLowerAscii().endsWith(".gguf"):
      continue
    let name = splitFile(path).name
    if isMmprojName(name):
      if mmprojPath.len == 0:
        mmprojPath = path
      continue
    let size = getFileSize(path)
    if size > bestSize:
      bestSize = size
      bestPath = path
  (bestPath, mmprojPath)

proc scanModelsDir*(dir: string): seq[ModelPreset] =
  ## Scans immediate subfolders of `dir` and builds one preset per folder,
  ## treating each folder as a single model. This avoids listing vision
  ## projector / addon `.gguf` files as separate top-level models. Within a
  ## folder, the largest non-mmproj `.gguf` is used as the model weights,
  ## and any mmproj/vision `.gguf` is attached as the model's `mmprojPath`.
  result = @[]
  if not dirExists(dir):
    return
  var first = true
  for kind, folder in walkDir(dir):
    if kind != pcDir:
      continue
    let (modelPath, mmprojPath) = findModelGgufsInFolder(folder)
    if modelPath.len == 0:
      continue
    result.add(ModelPreset(
      id: idFromPath(folder),
      modelPath: modelPath,
      mmprojPath: mmprojPath,
      ctxSize: 65536,
      nGpuLayers: "999",
      chatTemplateKwargs: """{"reasoning_effort":"medium"}""",
      temperature: 1.0,
      topP: 0.95,
      topK: 20,
      minP: 0.0,
      presencePenalty: 0.0,
      loadOnStartup: first,
    ))
    first = false

proc renderPreset(p: ModelPreset): string =
  result.add(&"[{p.id}]\n")
  result.add(&"model = {p.modelPath}\n")
  if p.mmprojPath.len > 0:
    result.add(&"mmproj = {p.mmprojPath}\n")
  result.add(&"c = {p.ctxSize}\n")
  result.add(&"n-gpu-layers = {p.nGpuLayers}\n")
  if p.chatTemplateKwargs.len > 0:
    result.add(&"chat-template-kwargs = {p.chatTemplateKwargs}\n")
  result.add(&"temp = {p.temperature}\n")
  result.add(&"top-p = {p.topP}\n")
  result.add(&"top-k = {p.topK}\n")
  result.add(&"min-p = {p.minP}\n")
  result.add(&"presence-penalty = {p.presencePenalty}\n")
  result.add(&"load-on-startup = {p.loadOnStartup}\n")

proc renderIni*(presets: seq[ModelPreset]): string =
  presets.mapIt(renderPreset(it)).join("\n")

proc writePresets*(path: string, presets: seq[ModelPreset]) =
  createDir(parentDir(path))
  writeFile(path, renderIni(presets))

proc ensurePresetsFile*(path: string, modelsDir: string) =
  ## Regenerates the preset file from a scan of `modelsDir` on every
  ## startup, falling back to the hardcoded default if no models are found.
  var presets = scanModelsDir(modelsDir)
  if presets.len == 0:
    logInfo("preset", "no model folders found under " & modelsDir & ", falling back to default preset")
    presets = defaultPresets()
  else:
    logInfo("preset", "discovered " & $presets.len & " model(s) under " & modelsDir)
  writePresets(path, presets)
