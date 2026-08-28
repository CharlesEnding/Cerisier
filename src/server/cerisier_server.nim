## cerisier-server: Prologue web app + agent orchestrator + llama-server
## router supervisor. Entry point wiring all modules together.

import std/[os, tables, asyncdispatch]
import prologue
import ./config
import ./db/database
import ./llama/[process, preset, router_client, session]
import ./agent/conversation
import ./tools/registry
import ./web/routes

proc superviseRouter(pm: ProcessManager) {.async.} =
  ## Runs for the lifetime of the server: periodically drains the router
  ## process's output (so recent lines are available if it crashes) and
  ## checks whether it has died unexpectedly, restarting it with backoff
  ## and logging the reason (best-effort) when it has.
  while true:
    await sleepAsync(3000)
    pm.drainOutput()
    discard pm.pollAndRestartIfCrashed()

when isMainModule:
  let root = getAppDir().parentDir().parentDir() # src/server -> project root
  let cfg = config.loadConfig(root)
  ensureDirs(cfg)

  let db = database.open(cfg.dbPath)
  db.migrate()

  ensurePresetsFile(db, cfg.presetsPath, cfg.modelsDir)

  let router = newRouterClient(cfg.llamaHost, cfg.llamaPort)
  let orchestrator = newOrchestrator(db, router)
  let toolRegistry = newToolRegistry(cfg.toolsDir)

  let pm = newProcessManager(cfg)
  pm.start()
  asyncCheck superviseRouter(pm)

  routes.state = AppState(db: db, router: router, orchestrator: orchestrator,
    staticDir: root / "web" / "static", chatSessions: initTable[int64, LlamaSession](),
    toolRegistry: toolRegistry, presetsPath: cfg.presetsPath, pm: pm)

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
  app.get("/history", historyPage)
  app.get("/models", modelsPage)
  app.post("/models/load", modelsLoadPost)
  app.post("/models/unload", modelsUnloadPost)
  app.get("/models/edit/{id}", modelsEditGet)
  app.post("/models/save", modelsSavePost)
  app.post("/models/delete", modelsDeletePost)
  app.get("/tools", toolsPage)
  app.post("/tools/approve", toolsApprovePost)
  app.post("/tools/deny", toolsDenyPost)
  app.get("/skills", skillsPage)
  app.post("/skills/new", skillsNewPost)
  app.post("/skills/delete", skillsDeletePost)
  app.get("/formats", formatsPage)
  app.post("/formats/new", formatsNewPost)
  app.get("/ws/chat/{id}", wsChat)
  app.get("/static/{file}", staticAsset)

  app.run()
