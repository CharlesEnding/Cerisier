## cerisier-server: Prologue web app + agent loop, talking to an
## OpenAI-compatible model backend. Entry point wiring all modules together.

import std/[os, tables, asyncdispatch]
import prologue
import ./config
import ./db/database
import ./api/[client, session]
import ./agent/[conversation, loop, sysinfo]
import ./tools/registry
import ./tools/executor
import ./web/routes
import ./web/openai

when isMainModule:
  let root = getAppDir().parentDir().parentDir() # src/server -> project root
  let cfg = config.loadConfig(root)
  ensureDirs(cfg)
  initSystemInfo()

  let db = database.open(cfg.dbPath)
  db.migrate()

  let api = newApiClient(cfg.apiUrl, cfg.apiKey)
  let orchestrator = newOrchestrator(db)
  let toolRegistry = newToolRegistry(cfg.toolsDir)
  let toolExecutor = newToolExecutor(db, toolRegistry)

  routes.state = AppState(cfg: cfg, db: db, api: api, orchestrator: orchestrator,
    staticDir: root / "web" / "static", chatSessions: initTable[int64, ChatSession](),
    toolRegistry: toolRegistry, toolExecutor: toolExecutor,
    loop: LoopEnv(db: db, api: api, registry: toolRegistry, executor: toolExecutor, dataDir: cfg.dataDir, promptFile: cfg.promptFile),
    pendingApprovals: initTable[int64, Future[void]](), dataDir: cfg.dataDir)

  var app = newApp(settings = newSettings(
    appName = "cerisier",
    address = cfg.host,
    port = Port(cfg.port),
    debug = true,
  ))

  app.get("/", chatPage)
  app.get("/chat/{id}", chatPageWithId)
  app.get("/conversations/new", newConversationGet)
  app.post("/chat/{id}/model", chatModelPost)
  app.post("/chat/{id}/effort", chatEffortPost)
  app.post("/chat/{id}/todos/clear", todosClearPost)
  app.get("/chat/{id}/workdir", workdirGet)
  app.post("/chat/{id}/workdir", workdirPost)
  app.post("/chat/{id}/upload", uploadPost)
  app.get("/files/{fid}", fileGet)
  app.get("/history", historyPage)
  app.get("/models", modelsPage)
  app.post("/models/load", modelsLoadPost)
  app.post("/models/unload", modelsUnloadPost)
  app.get("/models/status.json", modelsStatusJson)
  app.get("/tools", toolsPage)
  app.get("/tools/edit/{name}", toolsEditGet)
  app.post("/tools/new", toolsNewPost)
  app.post("/tools/edit", toolsEditPost)
  app.post("/tools/delete", toolsDeletePost)
  app.get("/skills", skillsPage)
  app.post("/skills/new", skillsNewPost)
  app.post("/skills/delete", skillsDeletePost)
  app.get("/formats", formatsPage)
  app.post("/formats/new", formatsNewPost)
  app.get("/ws/chat/{id}", wsChat)
  app.get("/static/{file}", staticAsset)
  app.get("/v1/models", v1Models)
  app.post("/v1/chat/completions", v1ChatCompletions)

  app.run()
