## cerisier-server: Prologue web app + agent orchestrator + llama-server
## router supervisor. Entry point wiring all modules together.

import std/[os]
import prologue
import ./config
import ./db/database
import ./llama/[process, preset, router_client]
import ./agent/conversation
import ./web/routes

when isMainModule:
  let root = getAppDir().parentDir().parentDir() # src/server -> project root
  let cfg = config.loadConfig(root)
  ensureDirs(cfg)
  ensurePresetsFile(cfg.presetsPath)

  let db = database.open(cfg.dbPath)
  db.migrate()

  let router = newRouterClient(cfg.llamaHost, cfg.llamaPort)
  let orchestrator = newOrchestrator(db, router)

  routes.state = AppState(db: db, router: router, orchestrator: orchestrator, staticDir: root / "web" / "static")

  let pm = newProcessManager(cfg)
  pm.start()

  var app = newApp(settings = newSettings(
    appName = "cerisier",
    address = cfg.host,
    port = Port(cfg.port),
    debug = true,
  ))

  app.get("/", chatPage)
  app.get("/history", historyPage)
  app.get("/models", modelsPage)
  app.post("/models/load", modelsLoadPost)
  app.post("/models/unload", modelsUnloadPost)
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
