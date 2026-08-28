## Generates and maintains the `models-preset.ini` file consumed by
## llama-server's router mode (`--models-preset`). Each preset section maps
## to a model the user has locally; keys mirror llama-server CLI flags
## without their leading dashes (see llama.cpp server docs).

import std/[os, strformat, tables, sequtils, strutils]

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

proc ensurePresetsFile*(path: string) =
  ## Writes the default preset set if no preset file exists yet.
  if not fileExists(path):
    writePresets(path, defaultPresets())
