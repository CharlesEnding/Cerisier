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

proc superviseRouterLoop(pm: ProcessManager) {.thread.} =
  ## Runs for the lifetime of the server on its own OS thread: periodically
  ## checks whether the router process has died unexpectedly, restarting it
  ## with backoff and logging the reason (best-effort) when it has. Also
  ## periodically drains the router's raw stdout/stderr into the log file
  ## so the /router page reflects near-real-time output instead of only a
  ## single dump at process exit.
  ##
  ## This deliberately runs on a plain OS thread with a blocking `sleep`,
  ## NOT as an `{.async.}` proc scheduled via `asyncCheck`/`sleepAsync` on
  ## std/asyncdispatch's global dispatcher. Prologue's default backend
  ## (`httpx`) implements its own internal event loop/reactor and never
  ## drives std/asyncdispatch's dispatcher itself — so a future scheduled
  ## via `asyncCheck` on that dispatcher simply never gets its callbacks
  ## run. That silently starved this exact loop for this project's entire
  ## debugging history: `drainAvailableOutput`/`pollAndRestartIfCrashed`
  ## were never actually being called even once, which is why the
  ## `/router` page only ever showed the synchronous `[cerisier]` lines
  ## written directly from HTTP route handlers (those run fine, driven by
  ## httpx's own request handling) and never any real `[stdout]` content
  ## from the router process itself, no matter what was fixed on the
  ## capture-mechanism or llama-server side.
  while true:
    sleep(250)
    pm.drainAvailableOutput()
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
  var supervisorThread: Thread[ProcessManager]
  createThread(supervisorThread, superviseRouterLoop, pm)

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
  app.get("/models/status.json", modelsStatusJson)
  app.get("/router", routerPage)
  app.get("/router/status.json", routerStatusJson)
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
