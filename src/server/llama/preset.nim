## Generates and maintains the `models-preset.ini` file consumed by
## llama-server's router mode (`--models-preset`). Each preset section maps
## to a model the user has locally; keys mirror llama-server CLI flags
## without their leading dashes (see llama.cpp server docs).
##
## The database (`model_presets` table) is the source of truth: this module
## seeds it with known-good defaults on first run, merges in any model
## folders discovered under `modelsDir` that aren't in the DB yet (without
## touching already-configured rows), then renders the ini file from the DB.

import std/[os, strformat, sequtils, strutils, options]
import ../log
import ../db/database

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
    configured*: bool

proc toModelPreset(row: ModelPresetRow): ModelPreset =
  ModelPreset(
    id: row.id,
    modelPath: row.modelPath,
    mmprojPath: row.mmprojPath,
    ctxSize: row.ctxSize,
    nGpuLayers: row.nGpuLayers,
    chatTemplateKwargs: row.chatTemplateKwargs,
    temperature: row.temperature,
    topP: row.topP,
    topK: row.topK,
    minP: row.minP,
    presencePenalty: row.presencePenalty,
    loadOnStartup: row.loadOnStartup,
    configured: row.configured,
  )

proc toRow(p: ModelPreset): ModelPresetRow =
  (
    id: p.id,
    modelPath: p.modelPath,
    mmprojPath: p.mmprojPath,
    ctxSize: p.ctxSize,
    nGpuLayers: p.nGpuLayers,
    chatTemplateKwargs: p.chatTemplateKwargs,
    temperature: p.temperature,
    topP: p.topP,
    topK: p.topK,
    minP: p.minP,
    presencePenalty: p.presencePenalty,
    loadOnStartup: p.loadOnStartup,
    configured: p.configured,
  )

proc defaultPresets*(): seq[ModelPreset] =
  ## Seeded from the models referenced in start-llama.sh, using the actual
  ## ctx-size/sampler values that file recorded for each one.
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
      configured: true,
    ),
    ModelPreset(
      id: "qwen3.6-35b-unc",
      modelPath: "/home/christian/models/qwen3.6-35b-UNC/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf",
      mmprojPath: "/home/christian/models/qwen3.6-35b-UNC/mmproj-Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-f16.gguf",
      ctxSize: 131072,
      nGpuLayers: "999",
      chatTemplateKwargs: """{"reasoning_effort":"medium"}""",
      temperature: 1.0,
      topP: 0.95,
      topK: 20,
      minP: 0.0,
      presencePenalty: 0.0,
      loadOnStartup: false,
      configured: true,
    ),
    ModelPreset(
      id: "qwen3.6-27b-unc",
      modelPath: "/home/christian/models/qwen3.6-27B-UNC/Qwen3.6-27B-NEO-CODE-HERE-2T-OT-Q6_K.gguf",
      mmprojPath: "/home/christian/models/qwen3.6-27B-UNC/mmproj-F16.gguf",
      ctxSize: 32760,
      nGpuLayers: "999",
      chatTemplateKwargs: """{"reasoning_effort":"medium"}""",
      temperature: 1.0,
      topP: 0.95,
      topK: 20,
      minP: 0.0,
      presencePenalty: 0.0,
      loadOnStartup: false,
      configured: true,
    ),
    ModelPreset(
      id: "muse-glimmer-30b-heretic",
      modelPath: "/home/christian/models/muse-glimmer-30B-heretic/Muse-Glimmer-30B-Heretic-Abliterated-BF16.Q6_K.gguf",
      mmprojPath: "",
      ctxSize: 65536,
      nGpuLayers: "999",
      chatTemplateKwargs: """{"reasoning_effort":"medium"}""",
      temperature: 1.0,
      topP: 0.95,
      topK: 20,
      minP: 0.0,
      presencePenalty: 0.0,
      loadOnStartup: false,
      configured: true,
    ),
  ]

proc idFromFolder(folder: string): string =
  ## `folder` is a directory path, not a file: using `splitFile` here would
  ## mis-split names that contain a dot (e.g. "qwen3.6-35b-UNC" -> "qwen3"),
  ## which is why every dotted-version qwen folder used to collapse onto a
  ## single "[qwen3]" section. Use the plain directory basename instead.
  extractFilename(folder.strip(chars = {'/'})).toLowerAscii().replace(" ", "-").replace("_", "-")

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

proc seedDefaultPresets*(db: Database) =
  ## Populates `model_presets` with the known-good defaults the first time
  ## the table is empty. Never called again once it has any rows.
  if db.countModelPresets() > 0:
    return
  logInfo("preset", "model_presets table empty, seeding defaults")
  for p in defaultPresets():
    db.upsertModelPreset(toRow(p))

proc discoverUnconfiguredModels*(db: Database, dir: string) =
  ## Scans immediate subfolders of `dir` and, for any model folder whose id
  ## isn't already present in the DB, inserts a placeholder row with
  ## generic fallback params and `configured = false`. Existing rows
  ## (configured or not) are left untouched so user edits always survive a
  ## restart / rescan.
  if not dirExists(dir):
    return
  for kind, folder in walkDir(dir):
    if kind != pcDir:
      continue
    let id = idFromFolder(folder)
    if db.getModelPreset(id).isSome:
      continue
    let (modelPath, mmprojPath) = findModelGgufsInFolder(folder)
    if modelPath.len == 0:
      continue
    logInfo("preset", "discovered unconfigured model folder: " & folder & " -> id=" & id)
    db.upsertModelPreset(toRow(ModelPreset(
      id: id,
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
      loadOnStartup: false,
      configured: false,
    )))

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

proc listAllPresets*(db: Database): seq[ModelPreset] =
  db.listModelPresets().mapIt(toModelPreset(it))

proc regeneratePresetsFile*(db: Database, path: string) =
  ## Re-renders the ini file from whatever is currently in the DB. Call
  ## this after any preset is saved/deleted from the /models page so
  ## llama-server picks it up on its next (re)start.
  writePresets(path, db.listAllPresets())

proc ensurePresetsFile*(db: Database, path: string, modelsDir: string) =
  ## Seeds defaults on an empty DB, merges in any newly discovered model
  ## folders under `modelsDir` (without touching existing rows), then
  ## renders the ini file from the DB.
  seedDefaultPresets(db)
  discoverUnconfiguredModels(db, modelsDir)
  let presets = db.listAllPresets()
  logInfo("preset", $presets.len & " preset(s) in DB")
  writePresets(path, presets)

