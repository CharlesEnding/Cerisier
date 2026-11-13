## Application configuration for cerisier-server.
## Loaded from a plain key=value config file, with sane defaults so the
## server can start with zero configuration on a fresh checkout.
##
## The model backend is any OpenAI-compatible `/v1` server (`api_url`). The
## models Cerisier may use are listed in a JSON file whose entries follow the
## shape of Zed's `available_models` (see `loadModels`).

import std/[os, strutils, tables, json]

type
  ModelEntry* = object
    name*: string               ## id sent to the backend as `model`
    displayName*: string
    maxTokens*: int             ## context window
    maxOutputTokens*: int
    reasoningEffort*: string    ## "" = don't send
    tools*: bool                ## backend supports native tool calls
    images*: bool               ## accepts image inputs

  Config* = object
    host*: string
    port*: int
    apiUrl*: string             ## base URL of the backend, including `/v1`
    apiKey*: string             ## bearer token for the backend ("" = none)
    serverToken*: string        ## bearer token required of /v1 clients ("" = open)
    modelManagement*: bool      ## enables load/unload calls (needs a backend that has them)
    modelsFile*: string
    models*: seq[ModelEntry]
    dataDir*: string            ## sqlite db + misc runtime data
    dbPath*: string
    toolsDir*: string           ## directory of *.tool.json manifests

const
  defaultMaxTokens* = 8192
  apiKeyEnv = "CERISIER_API_KEY"
  serverTokenEnv = "CERISIER_SERVER_TOKEN"

proc defaultConfig*(root: string): Config =
  result = Config(
    host: "127.0.0.1",
    port: 8888,
    apiUrl: "http://127.0.0.1:8000/v1",
    modelsFile: root / "config" / "models.json",
    dataDir: root / "data",
    dbPath: root / "data" / "cerisier.db",
    toolsDir: root / "tools",
  )

proc parseSimpleKv(path: string): Table[string, string] =
  result = initTable[string, string]()
  if not fileExists(path):
    return
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len == 0 or trimmed.startsWith('#'):
      continue
    let idx = trimmed.find('=')
    if idx < 0:
      continue
    let key = trimmed[0 ..< idx].strip()
    let value = trimmed[idx + 1 .. ^1].strip()
    result[key] = value

proc readSecret(envName, filePath: string): string =
  ## Environment variable wins; otherwise the first line of `filePath`.
  result = getEnv(envName)
  if result.len == 0 and filePath.len > 0 and fileExists(filePath):
    result = readFile(filePath).strip()

proc loadModels*(path: string): seq[ModelEntry] =
  ## A JSON array of `{name, display_name, max_tokens, max_output_tokens,
  ## reasoning_effort, capabilities: {tools, images}}`, or an object with that
  ## array under `available_models`. A missing file means "no entries".
  result = @[]
  if not fileExists(path):
    return
  var root = parseJson(readFile(path))
  if root.kind == JObject:
    root = root{"available_models"}
  if root == nil or root.kind != JArray:
    raise newException(ValueError, path & ": expected a JSON array of models")
  for node in root:
    let name = node{"name"}.getStr("")
    if name.len == 0:
      continue
    let caps = node{"capabilities"}
    result.add(ModelEntry(
      name: name,
      displayName: node{"display_name"}.getStr(name),
      maxTokens: node{"max_tokens"}.getInt(defaultMaxTokens),
      maxOutputTokens: node{"max_output_tokens"}.getInt(0),
      reasoningEffort: node{"reasoning_effort"}.getStr(""),
      tools: caps{"tools"}.getBool(false),
      images: caps{"images"}.getBool(false),
    ))

proc loadConfig*(root: string, configPath: string = ""): Config =
  ## Loads config from `configPath` (default `<root>/config/cerisier.conf`)
  ## overlaid on top of `defaultConfig`. Missing file is not an error.
  result = defaultConfig(root)
  let path = if configPath.len > 0: configPath else: root / "config" / "cerisier.conf"
  let kv = parseSimpleKv(path)
  var apiKeyFile = ""
  var serverTokenFile = ""
  for key, value in kv:
    case key
    of "host": result.host = value
    of "port": result.port = parseInt(value)
    of "api_url": result.apiUrl = value
    of "api_key_file": apiKeyFile = value
    of "server_token_file": serverTokenFile = value
    of "model_management": result.modelManagement = parseBool(value)
    of "models_file": result.modelsFile = value
    of "data_dir": result.dataDir = value
    of "db_path": result.dbPath = value
    of "tools_dir": result.toolsDir = value
    else: discard
  result.apiUrl = result.apiUrl.strip(chars = {'/'}, leading = false)
  result.apiKey = readSecret(apiKeyEnv, apiKeyFile)
  result.serverToken = readSecret(serverTokenEnv, serverTokenFile)
  result.models = loadModels(result.modelsFile)

proc ensureDirs*(cfg: Config) =
  createDir(cfg.dataDir)

proc findModel*(cfg: Config, name: string): ModelEntry =
  ## Entry for `name`, or a default one when the backend serves a model that
  ## isn't listed in the models file.
  for m in cfg.models:
    if m.name == name:
      return m
  ModelEntry(name: name, displayName: name, maxTokens: defaultMaxTokens)
