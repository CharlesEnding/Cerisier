## Application configuration for cerisier-server.
## Loaded from a plain key=value config file, with sane defaults so the
## server can start with zero configuration on a fresh checkout.

import std/[os, strutils, tables]

type
  Config* = object
    host*: string
    port*: int
    llamaServerBin*: string     ## path to the llama-server executable
    modelsDir*: string          ## --models-dir passed to llama-server router mode
    presetsPath*: string        ## --models-preset ini file we generate/maintain
    dataDir*: string            ## sqlite db + misc runtime data
    dbPath*: string
    llamaHost*: string          ## host/port the router listens on (loopback)
    llamaPort*: int

proc defaultConfig*(root: string): Config =
  result = Config(
    host: "0.0.0.0",
    port: 8888,
    llamaServerBin: "llama-server",
    modelsDir: root / "models",
    presetsPath: root / "config" / "models-preset.ini",
    dataDir: root / "data",
    dbPath: root / "data" / "cerisier.db",
    llamaHost: "127.0.0.1",
    llamaPort: 8081,
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

proc loadConfig*(root: string, configPath: string = ""): Config =
  ## Loads config from `configPath` (default `<root>/config/cerisier.conf`)
  ## overlaid on top of `defaultConfig`. Missing file is not an error.
  result = defaultConfig(root)
  let path = if configPath.len > 0: configPath else: root / "config" / "cerisier.conf"
  let kv = parseSimpleKv(path)
  for key, value in kv:
    case key
    of "host": result.host = value
    of "port": result.port = parseInt(value)
    of "llama_server_bin": result.llamaServerBin = value
    of "models_dir": result.modelsDir = value
    of "presets_path": result.presetsPath = value
    of "data_dir": result.dataDir = value
    of "db_path": result.dbPath = value
    of "llama_host": result.llamaHost = value
    of "llama_port": result.llamaPort = parseInt(value)
    else: discard

proc ensureDirs*(cfg: Config) =
  createDir(cfg.dataDir)
  createDir(cfg.modelsDir)
  createDir(parentDir(cfg.presetsPath))
