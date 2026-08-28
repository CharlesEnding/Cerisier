## HTTP + WebSocket routes for the Cerisier web UI.
## Every page is a normal server-rendered full page load, except the chat
## page's WebSocket channel which live-updates in place.

import std/[asyncdispatch, json, strformat, options, strutils, tables, sequtils, deques, times]
import prologue
import prologue/websocket
import ./layout
import ../db/database
import ../skills/skills
import ../formats/formats
import ../llama/router_client
import ../llama/session
import ../llama/preset
import ../llama/process
import ../agent/conversation
import ../tools/registry
import ../log
import ../../common/types

type
  AppState* = ref object
    db*: Database
    router*: RouterClient
    orchestrator*: ConversationOrchestrator
    staticDir*: string
    chatSessions*: Table[int64, LlamaSession] ## one live session per conversation, lazily created
    toolRegistry*: ToolRegistry
    presetsPath*: string
    pm*: ProcessManager ## router process supervisor, for status reporting in the UI
    lastLoadAttempt*: string ## "modelId at HH:mm:ss" of the most recent load attempt, for diagnostics

var state*: AppState

proc getState(): AppState {.gcsafe.} =
  {.cast(gcsafe).}:
    result = state

proc staticAsset*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let filename = ctx.getPathParams("file")
  await staticFileResponse(ctx, filename, s.staticDir)

proc routerStatusBanner(s: AppState): string =
  ## Rendered at the top of pages that talk to the router (chat, models) so
  ## a crashed/restarting router process is visible without digging through
  ## stdout logs.
  if s.pm == nil:
    return ""
  case s.pm.state
  of psRunning, psStarting:
    return ""
  of psCrashed:
    let attemptNote = if s.lastLoadAttempt.len > 0: &" Last load attempted: {s.lastLoadAttempt}." else: ""
    if s.pm.restartCount >= 5:
      return &"""<div class="router-banner">Router process crashed and auto-restart attempts are exhausted (last reason: {s.pm.lastCrashReason}).{attemptNote} Restart the server manually. See <a href="/router">Router status</a> for the diagnostic log.</div>"""
    else:
      return &"""<div class="router-banner">Router process crashed (last reason: {s.pm.lastCrashReason}) — restarting automatically (attempt {s.pm.restartCount}/5).{attemptNote} See <a href="/router">Router status</a> for the diagnostic log.</div>"""
  of psStopped:
    return """<div class="router-banner">Router process is not running. See <a href="/router">Router status</a>.</div>"""

proc noteLoadAttempt(s: AppState, modelId: string) =
  ## Records what was last attempted so the router-crashed banner and the
  ## /router diagnostics page can hint at what likely caused a crash, since
  ## a VRAM-OOM crash can happen a moment after the load request itself
  ## already returned (or the router died before responding at all).
  s.lastLoadAttempt = modelId & " at " & now().format("HH:mm:ss")

proc routerAwareFailureReason(s: AppState, fallback: string): string =
  ## Builds a chat-facing error message that names the router's actual
  ## state (crashed/stopped + reason) when available, instead of a generic
  ## "something went wrong" — this is what actually distinguishes a VRAM-OOM
  ## router crash from a transient/other failure for the user.
  if s.pm == nil:
    return fallback
  case s.pm.state
  of psCrashed:
    result = "router process crashed (reason: " & s.pm.lastCrashReason & ")"
    if s.pm.restartCount < 5:
      result.add(" — restarting automatically")
    result.add(". See the Router page for details.")
  of psStopped:
    result = "router process is not running. See the Router page for details."
  of psStarting, psRunning:
    result = fallback

# ---------------- Chat (the one live-updating page) ----------------

proc renderChatPage(ctx: Context, requestedId: Option[int64]) {.async, gcsafe.} =
  let s = getState()
  let existing = s.db.listConversations()
  var currentId: int64
  if requestedId.isSome and existing.anyIt(it[0] == requestedId.get()):
    currentId = requestedId.get()
  elif existing.len == 0:
    currentId = s.orchestrator.startConversation("New conversation")
  else:
    currentId = existing[0][0]
  var log = ""
  for (id, parentId, role, content, createdAt) in s.db.messagesForConversation(currentId):
    if role == "reasoning":
      log.add(&"<details class=\"reasoning\"><summary>Reasoning</summary><div>{content}</div></details>\n")
    else:
      log.add(&"<div class=\"msg {role}\">{content}</div>\n")
  let title = s.db.getConversationTitle(currentId)
  var currentModel = ""
  var modelOptions = ""
  try:
    let models = await s.router.listModels()
    ## Prefer whatever the router itself reports as loaded — this is the
    ## ground truth. The cached chat session's `model` field is only a
    ## fallback for when nothing is loaded yet or the router is unreachable,
    ## since it can go stale the moment a model is loaded/unloaded outside
    ## of this conversation (e.g. from the /models page).
    for m in models:
      if m.status == msvLoaded:
        currentModel = m.id
        break
    if currentModel.len == 0 and s.chatSessions.hasKey(currentId):
      currentModel = s.chatSessions[currentId].model
    for m in models:
      let selected = if m.id == currentModel: " selected" else: ""
      modelOptions.add(&"<option value=\"{m.id}\"{selected}>{m.id} ({m.status})</option>")
  except CatchableError as e:
    logError("router", "listModels failed: " & e.msg)
  let body = &"""
  {routerStatusBanner(s)}
  <div id="chat-header">
    <h1 id="chat-title">{title}</h1>
    <label for="model-select">Model:</label>
    <select id="model-select">{modelOptions}</select>
  </div>
  <div id="chat-log">{log}</div>
  <form id="chat-form">
    <input id="chat-input" type="text" placeholder="Message..." autocomplete="off">
    <button type="submit">Send</button>
    <button type="button" id="stop-btn" style="display:none">Stop</button>
  </form>
  <script>connectChat({currentId});</script>
  """
  resp htmlResponse(page("Chat", "/", body))

proc chatPage*(ctx: Context) {.async, gcsafe.} =
  logInfo("routes", "GET /")
  await renderChatPage(ctx, none(int64))

proc chatPageWithId*(ctx: Context) {.async, gcsafe.} =
  let idStr = ctx.getPathParams("id")
  logInfo("routes", "GET /chat/" & idStr)
  try:
    await renderChatPage(ctx, some(parseBiggestInt(idStr).int64))
  except ValueError:
    await renderChatPage(ctx, none(int64))

proc newConversationGet*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let newId = s.orchestrator.startConversation("New conversation")
  logInfo("routes", "GET /conversations/new -> " & $newId)
  resp redirect("/chat/" & $newId)

# ---------------- Router status (diagnostics) ----------------

proc escapeHtml(s: string): string =
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    else: result.add(c)

proc routerPage*(ctx: Context) {.async, gcsafe.} =
  logInfo("routes", "GET /router")
  let s = getState()
  if s.pm == nil:
    resp htmlResponse(page("Router", "/router", "<h1>Router</h1><p>No process supervisor configured.</p>"))
    return
  let stateLabel =
    case s.pm.state
    of psRunning: "running"
    of psStarting: "starting"
    of psCrashed: "crashed"
    of psStopped: "stopped"
  let attemptRow = if s.lastLoadAttempt.len > 0: &"<tr><td>Last load attempt</td><td>{escapeHtml(s.lastLoadAttempt)}</td></tr>" else: ""
  let crashRow = if s.pm.lastCrashReason.len > 0: &"<tr><td>Last crash reason</td><td>{escapeHtml(s.pm.lastCrashReason)}</td></tr>" else: ""
  let stats = s.pm.logFileStats()
  let logStatsRow =
    if stats.exists: &"<tr><td>Log file</td><td>{escapeHtml(s.pm.logFile)} ({stats.sizeBytes} bytes, last written {escapeHtml(stats.lastModified)})</td></tr>"
    else: &"<tr><td>Log file</td><td>{escapeHtml(s.pm.logFile)} (does not exist yet)</td></tr>"
  var logLines = ""
  for line in s.pm.recentOutput():
    logLines.add(escapeHtml(line) & "\n")
  if logLines.len == 0:
    logLines = "(no output captured yet)"
  let body = &"""<h1>Router status</h1>
  <table>
    <tr><td>State</td><td>{stateLabel}</td></tr>
    <tr><td>Restart count</td><td>{s.pm.restartCount} / 5</td></tr>
    <tr><td>Last exit code</td><td>{s.pm.lastExitCode}</td></tr>
    {crashRow}
    {attemptRow}
    {logStatsRow}
  </table>
  <p><a href="/router">Refresh</a></p>
  <h2>Recent router output (stdout/stderr)</h2>
  <pre id="router-log">{logLines}</pre>"""
  resp htmlResponse(page("Router", "/router", body))

proc historyPage*(ctx: Context) {.async, gcsafe.} =
  logInfo("routes", "GET /history")
  let s = getState()
  var rows = ""
  for (id, title, createdAt) in s.db.listConversations():
    rows.add(&"<tr><td><a href=\"/chat/{id}\">{title}</a></td><td>{createdAt}</td></tr>\n")
  let body = &"<h1>History</h1><table><tr><th>Title</th><th>Created</th></tr>{rows}</table>"
  resp htmlResponse(page("History", "/history", body))

# ---------------- Models ----------------

proc routerStatusJson*(ctx: Context) {.async, gcsafe.} =
  ## Polled by the frontend after a load/switch is accepted, since the
  ## router may accept a load request and only crash later (in the
  ## background) once VRAM actually runs out — the initial HTTP response
  ## can't know that yet. This lets the UI catch up once it does.
  let s = getState()
  if s.pm == nil:
    resp jsonResponse(%*{"state": "unknown"})
    return
  let stateLabel =
    case s.pm.state
    of psRunning: "running"
    of psStarting: "starting"
    of psCrashed: "crashed"
    of psStopped: "stopped"
  resp jsonResponse(%*{
    "state": stateLabel,
    "restartCount": s.pm.restartCount,
    "lastExitCode": s.pm.lastExitCode,
    "lastCrashReason": s.pm.lastCrashReason,
    "lastLoadAttempt": s.lastLoadAttempt,
    "logSizeBytes": s.pm.logFileStats().sizeBytes,
  })

proc modelsStatusJson*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  try:
    let models = await s.router.listModels()
    var arr = newJArray()
    for m in models:
      arr.add(%*{"id": m.id, "status": $m.status})
    resp jsonResponse(%*{"success": true, "models": arr})
  except CatchableError as e:
    resp jsonResponse(%*{"success": false, "error": e.msg})

proc modelsPage*(ctx: Context) {.async, gcsafe.} =
  logInfo("routes", "GET /models")
  let s = getState()
  var rows = ""
  try:
    let models = await s.router.listModels()
    logInfo("router", "listModels -> " & $models.len & " model(s)")
    for m in models:
      rows.add(&"""<tr id="model-row-{m.id}"><td>{m.id}</td><td class="model-status">{m.status}</td><td>{m.supportsVision}</td>
        <td>
          <button type="button" class="load-btn" data-model="{m.id}">Load</button>
          <button type="button" class="unload-btn" data-model="{m.id}">Unload</button>
          <span class="model-msg"></span>
        </td></tr>""")
  except CatchableError as e:
    logError("router", "listModels failed: " & e.msg)
    rows = &"<tr><td colspan=4>router unreachable: {e.msg}</td></tr>"
  var presetRows = ""
  for p in preset.listAllPresets(s.db):
    let configuredLabel = if p.configured: "yes" else: "no (discovered)"
    presetRows.add(&"""<tr><td>{p.id}</td><td>{p.modelPath}</td><td>{p.ctxSize}</td>
      <td>{configuredLabel}</td><td>{p.loadOnStartup}</td>
      <td>
        <a href="/models/edit/{p.id}">Edit</a>
        <form class="inline" method="post" action="/models/delete"><input type="hidden" name="id" value="{p.id}"><button>Delete</button></form>
      </td></tr>""")
  let body = &"""{routerStatusBanner(s)}
  <h1>Models</h1>
  <table id="models-table"><tr><th>Model</th><th>Status</th><th>Vision</th><th>Actions</th></tr>{rows}</table>
  <h2>Presets</h2>
  <p>Stored in the database; edited here and rendered into <code>models-preset.ini</code> for llama-server's router mode. Requires a router restart to take effect.</p>
  <table><tr><th>Id</th><th>Model path</th><th>Ctx</th><th>Configured</th><th>Load on startup</th><th>Actions</th></tr>{presetRows}</table>
  <h2>New preset</h2>
  <form method="post" action="/models/save">
    <p>Id: <input name="id"></p>
    <p>Model path: <input name="model_path" size="60"></p>
    <p>Mmproj path: <input name="mmproj_path" size="60"></p>
    <p>Ctx size: <input name="ctx_size" value="65536"></p>
    <p>N GPU layers: <input name="n_gpu_layers" value="999"></p>
    <p>Chat template kwargs (JSON): <input name="chat_template_kwargs" value='{{"reasoning_effort":"medium"}}' size="40"></p>
    <p>Temperature: <input name="temperature" value="1.0"></p>
    <p>Top-p: <input name="top_p" value="0.95"></p>
    <p>Top-k: <input name="top_k" value="20"></p>
    <p>Min-p: <input name="min_p" value="0.0"></p>
    <p>Presence penalty: <input name="presence_penalty" value="0.0"></p>
    <p>Load on startup: <input type="checkbox" name="load_on_startup" value="1"></p>
    <p><button type="submit">Save</button></p>
  </form>"""
  resp htmlResponse(page("Models", "/models", body))


proc modelsLoadPost*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let payload = parseJson(ctx.request.body)
  let model = payload{"model"}.getStr("")
  try:
    ## The router/GPU may not have room for two models at once: unload
    ## whatever else is currently reported loaded before loading the
    ## requested one, mirroring `switchChatModel`'s behavior. Without this,
    ## a failed load previously left the *other* (e.g. default/startup)
    ## model loaded with no indication anything went wrong.
    if s.pm != nil: s.pm.logAppend("load requested model=" & model)
    let currentModels = await s.router.listModels()
    for m in currentModels:
      if m.status == msvLoaded and m.id != model:
        let unloadRes = await s.router.unloadModel(m.id)
        if s.pm != nil: s.pm.logAppend("unload (pre-load) model=" & m.id & " success=" & $unloadRes.success & " error=" & unloadRes.error)
        if not unloadRes.success:
          logError("router", "unload " & m.id & " before loading " & model & " failed: " & unloadRes.error)
    let res = await s.router.loadModel(model)
    noteLoadAttempt(s, model)
    if s.pm != nil: s.pm.logAppend("load result model=" & model & " success=" & $res.success & " error=" & res.error)
    if res.success:
      resp jsonResponse(%*{"success": true})
    else:
      resp jsonResponse(%*{"success": false, "error": res.error})
  except CatchableError as e:
    if s.pm != nil: s.pm.logAppend("load result model=" & model & " success=false error=" & e.msg)
    logError("routes", "load model " & model & " failed: " & e.msg)
    resp jsonResponse(%*{"success": false, "error": e.msg})

proc modelsUnloadPost*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let payload = parseJson(ctx.request.body)
  let model = payload{"model"}.getStr("")
  try:
    if s.pm != nil: s.pm.logAppend("unload requested model=" & model)
    let res = await s.router.unloadModel(model)
    if s.pm != nil: s.pm.logAppend("unload result model=" & model & " success=" & $res.success & " error=" & res.error)
    if res.success:
      resp jsonResponse(%*{"success": true})
    else:
      resp jsonResponse(%*{"success": false, "error": res.error})
  except CatchableError as e:
    if s.pm != nil: s.pm.logAppend("unload result model=" & model & " success=false error=" & e.msg)
    logError("routes", "unload model " & model & " failed: " & e.msg)
    resp jsonResponse(%*{"success": false, "error": e.msg})

proc modelsEditGet*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let id = ctx.getPathParams("id")
  let existing = database.getModelPreset(s.db, id)
  if existing.isNone:
    resp redirect("/models")
    return
  let p = existing.get()
  let checked = if p.loadOnStartup: "checked" else: ""
  let body = &"""<h1>Edit preset: {p.id}</h1>
  <form method="post" action="/models/save">
    <input type="hidden" name="id" value="{p.id}">
    <p>Model path: <input name="model_path" value="{p.modelPath}" size="60"></p>
    <p>Mmproj path: <input name="mmproj_path" value="{p.mmprojPath}" size="60"></p>
    <p>Ctx size: <input name="ctx_size" value="{p.ctxSize}"></p>
    <p>N GPU layers: <input name="n_gpu_layers" value="{p.nGpuLayers}"></p>
    <p>Chat template kwargs (JSON): <input name="chat_template_kwargs" value='{p.chatTemplateKwargs}' size="40"></p>
    <p>Temperature: <input name="temperature" value="{p.temperature}"></p>
    <p>Top-p: <input name="top_p" value="{p.topP}"></p>
    <p>Top-k: <input name="top_k" value="{p.topK}"></p>
    <p>Min-p: <input name="min_p" value="{p.minP}"></p>
    <p>Presence penalty: <input name="presence_penalty" value="{p.presencePenalty}"></p>
    <p>Load on startup: <input type="checkbox" name="load_on_startup" value="1" {checked}></p>
    <p><button type="submit">Save</button></p>
  </form>"""
  resp htmlResponse(page("Edit preset", "/models", body))

proc modelsSavePost*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let id = ctx.getFormParams("id").strip()
  if id.len == 0:
    resp redirect("/models")
    return
  let row: ModelPresetRow = (
    id: id,
    modelPath: ctx.getFormParams("model_path"),
    mmprojPath: ctx.getFormParams("mmproj_path"),
    ctxSize: parseInt(ctx.getFormParams("ctx_size")),
    nGpuLayers: ctx.getFormParams("n_gpu_layers"),
    chatTemplateKwargs: ctx.getFormParams("chat_template_kwargs"),
    temperature: parseFloat(ctx.getFormParams("temperature")),
    topP: parseFloat(ctx.getFormParams("top_p")),
    topK: parseInt(ctx.getFormParams("top_k")),
    minP: parseFloat(ctx.getFormParams("min_p")),
    presencePenalty: parseFloat(ctx.getFormParams("presence_penalty")),
    loadOnStartup: ctx.getFormParams("load_on_startup") == "1",
    configured: true,
  )
  database.upsertModelPreset(s.db, row)
  preset.regeneratePresetsFile(s.db, s.presetsPath)
  resp redirect("/models")

proc modelsDeletePost*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let id = ctx.getFormParams("id")
  database.deleteModelPreset(s.db, id)
  preset.regeneratePresetsFile(s.db, s.presetsPath)
  resp redirect("/models")



# ---------------- Tools (existing tools available to the agent) ----------------

proc toolsPage*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  var rows = ""
  for t in s.toolRegistry.tools:
    rows.add(&"""<tr><td>{t.name}</td><td>{t.description}</td><td>{t.kind}</td><td>{t.location}</td><td><code>{t.entrypoint}</code></td><td>{t.autoRun}</td></tr>""")
  let body = &"""<h1>Tools</h1>
  <p>Purpose-built scripts and executables available to the agent. Approval of individual tool calls happens inline in the chat, not here.</p>
  <table><tr><th>Name</th><th>Description</th><th>Kind</th><th>Location</th><th>Entrypoint</th><th>Auto-run</th></tr>{rows}</table>"""
  resp htmlResponse(page("Tools", "/tools", body))

proc toolsApprovePost*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let id = parseInt(ctx.getFormParams("id"))
  s.db.setToolCallStatus(id, "approved")
  resp redirect("/tools")

proc toolsDenyPost*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let id = parseInt(ctx.getFormParams("id"))
  s.db.setToolCallStatus(id, "denied")
  resp redirect("/tools")

# ---------------- Skills ----------------

proc skillsPage*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  var rows = ""
  for sk in skills.listSkills(s.db):
    rows.add(&"""<tr><td>{sk.name}</td><td>{sk.description}</td>
      <td><form class="inline" method="post" action="/skills/delete"><input type="hidden" name="id" value="{sk.id}"><button>Delete</button></form></td></tr>""")
  let body = &"""<h1>Skills</h1>
  <table><tr><th>Name</th><th>Description</th><th></th></tr>{rows}</table>
  <h2>New skill</h2>
  <form method="post" action="/skills/new">
    <p>Name: <input name="name"></p>
    <p>Description: <input name="description"></p>
    <p>Prompt template ({{{{placeholders}}}} supported):<br><textarea name="prompt_template" rows="4" cols="60"></textarea></p>
    <p><button type="submit">Save</button></p>
  </form>"""
  resp htmlResponse(page("Skills", "/skills", body))

proc skillsNewPost*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let name = ctx.getFormParams("name")
  let description = ctx.getFormParams("description")
  let promptTemplate = ctx.getFormParams("prompt_template")
  saveSkill(s.db, name, description, promptTemplate, "")
  resp redirect("/skills")

proc skillsDeletePost*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let id = parseInt(ctx.getFormParams("id"))
  removeSkill(s.db, id)
  resp redirect("/skills")

# ---------------- Formats ----------------

proc formatsPage*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  var rows = ""
  for f in listFormatDefs(s.db):
    rows.add(&"<tr><td>{f.tag}</td><td>{f.cssClass}</td><td>{f.description}</td></tr>")
  let body = &"""<h1>Formats</h1>
  <p>Inline markup: <code>[[tag:param]]...[[/tag]]</code></p>
  <table><tr><th>Tag</th><th>CSS class</th><th>Description</th></tr>{rows}</table>
  <h2>New format</h2>
  <form method="post" action="/formats/new">
    <p>Tag: <input name="tag"></p>
    <p>CSS class: <input name="css_class"></p>
    <p>Description: <input name="description"></p>
    <p><button type="submit">Save</button></p>
  </form>"""
  resp htmlResponse(page("Formats", "/formats", body))

proc formatsNewPost*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let tag = ctx.getFormParams("tag")
  let cssClass = ctx.getFormParams("css_class")
  let description = ctx.getFormParams("description")
  saveFormat(s.db, tag, cssClass, description)
  resp redirect("/formats")

# ---------------- WebSocket: chat live updates ----------------

proc pickChatModel(s: AppState): Future[string] {.async.} =
  let models = await s.router.listModels()
  for m in models:
    if m.status == msvLoaded:
      return m.id
  if models.len > 0:
    if s.pm != nil: s.pm.logAppend("load requested model=" & models[0].id & " (auto-pick for new chat session)")
    let res = await s.router.loadModel(models[0].id)
    noteLoadAttempt(s, models[0].id)
    if s.pm != nil: s.pm.logAppend("load result model=" & models[0].id & " success=" & $res.success & " error=" & res.error)
    if not res.success:
      raise newException(CatchableError, "failed to load model " & models[0].id & ": " & res.error)
    return models[0].id
  raise newException(CatchableError, "no models available")

proc getOrCreateChatSession(s: AppState, convId: int64): Future[LlamaSession] {.async.} =
  if s.chatSessions.hasKey(convId):
    return s.chatSessions[convId]
  let model = await pickChatModel(s)
  result = newLlamaSession(s.db, s.router, convId, none(int64), model, "chat", 8192)
  s.chatSessions[convId] = result

proc switchChatModel(s: AppState, convId: int64, modelId: string): Future[ModelOpResult] {.async.} =
  ## Unloads whatever the router reports as currently loaded (if different
  ## from the target) before loading the requested one, since the
  ## router/GPU may not have room to keep both loaded at once. This checks
  ## the router's live status rather than the cached session's model, since
  ## the two can disagree (e.g. a model was loaded/unloaded from the
  ## /models page). Returns a failed `ModelOpResult` (without touching the
  ## cached session) if the load fails, so a failed switch doesn't silently
  ## strand the conversation on a half-switched state.
  if s.pm != nil: s.pm.logAppend("load requested model=" & modelId & " (chat model switch)")
  let currentModels = await s.router.listModels()
  for m in currentModels:
    if m.status == msvLoaded and m.id != modelId:
      let unloadRes = await s.router.unloadModel(m.id)
      if s.pm != nil: s.pm.logAppend("unload (pre-load) model=" & m.id & " success=" & $unloadRes.success & " error=" & unloadRes.error)
      if not unloadRes.success:
        logError("router", "unload " & m.id & " before switching to " & modelId & " failed: " & unloadRes.error)
  let loadRes = await s.router.loadModel(modelId)
  noteLoadAttempt(s, modelId)
  if s.pm != nil: s.pm.logAppend("load result model=" & modelId & " success=" & $loadRes.success & " error=" & loadRes.error)
  if not loadRes.success:
    return loadRes
  s.chatSessions[convId] = newLlamaSession(s.db, s.router, convId, none(int64), modelId, "chat", 8192)
  ModelOpResult(success: true, error: "")

proc chatModelPost*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let convId = parseBiggestInt(ctx.getPathParams("id")).int64
  let payload = parseJson(ctx.request.body)
  let modelId = payload{"model"}.getStr("")
  try:
    let res = await switchChatModel(s, convId, modelId)
    if res.success:
      logInfo("routes", "conversation " & $convId & " switched to model " & modelId)
      resp jsonResponse(%*{"success": true})
    else:
      logError("routes", "conversation " & $convId & " failed to switch to model " & modelId & ": " & res.error)
      resp jsonResponse(%*{"success": false, "error": res.error})
  except CatchableError as e:
    logError("routes", "model switch failed: " & $e.name & ": " & e.msg)
    resp jsonResponse(%*{"success": false, "error": e.msg})

const titleGenThreshold = 3 ## generate a topic title once a conversation reaches this many messages

proc maybeGenerateTitle(s: AppState, convId: int64, sess: LlamaSession,
                         history: seq[(string, string)]): Future[Option[string]] {.async.} =
  ## After a few messages, ask the model for a short topic title and store
  ## it, replacing the default "New conversation" placeholder.
  if history.len < titleGenThreshold:
    return none(string)
  if s.db.getConversationTitle(convId) != "New conversation":
    return none(string)
  try:
    let prompt = @[("user", "In 3-6 words, give a short topic title for this " &
                            "conversation. Reply with only the title, no punctuation.")]
    let rawTitle = await sess.sendTurn(history & prompt)
    let title = rawTitle.strip(chars = {' ', '\n', '\t', '"', '.'})
    if title.len > 0:
      s.db.updateConversationTitle(convId, title)
      return some(title)
  except CatchableError as e:
    logInfo("routes", "title generation failed: " & $e.name & ": " & e.msg)
  none(string)

type
  ChatTurnState = ref object
    ## Heap-allocated shared state for one WebSocket connection's in-flight
    ## turn. Deliberately NOT captured as plain `var` locals closed over by
    ## a nested async proc: nested async closures over outer-proc locals
    ## have triggered segfaults on this toolchain, so the mutable state
    ## lives on its own ref object instead and every callback closes over
    ## that ref (safe) rather than the enclosing proc's stack frame.
    generating: bool
    cancelled: bool

  TokenQueue = ref object
    ## Unbounded queue decoupling llama.cpp's token stream from the
    ## WebSocket send. `onToken`/`onReasoning` push and return immediately
    ## (no data is ever dropped), so `postJsonStream`'s read loop is never
    ## blocked waiting on network I/O for the browser.
    ##
    ## `runSender` drains and sends the *entire* backlog as a single batched
    ## WebSocket frame per cycle rather than one frame per token. Sending
    ## one frame per token let the queue grow without bound whenever the
    ## socket couldn't keep up with generation speed — the accumulating
    ## deque/JsonNode garbage caused ever-longer GC pauses, which is what
    ## made replies appear to "slow to a crawl" midway through. Batching
    ## keeps the number of sends bounded by how fast the browser drains the
    ## socket, not by how many tokens llama.cpp produced.
    items: Deque[JsonNode]
    notEmpty: Future[void]
    closed: bool

proc newTokenQueue(): TokenQueue =
  TokenQueue(items: initDeque[JsonNode](), notEmpty: newFuture[void]("TokenQueue.notEmpty"), closed: false)

proc push(q: TokenQueue, item: JsonNode) =
  q.items.addLast(item)
  if not q.notEmpty.finished:
    q.notEmpty.complete()

proc closeQueue(q: TokenQueue) =
  q.closed = true
  if not q.notEmpty.finished:
    q.notEmpty.complete()

proc runSender(ws: WebSocket, q: TokenQueue): Future[void] {.async, gcsafe.} =
  ## Drains `q` and sends its current backlog as one batched frame, in
  ## order, until the queue is closed and empty. Runs concurrently with
  ## (never blocks) token production.
  while true:
    if q.items.len == 0:
      if q.closed:
        break
      await q.notEmpty
      q.notEmpty = newFuture[void]("TokenQueue.notEmpty")
      continue
    var batch = newJArray()
    while q.items.len > 0:
      batch.add(q.items.popFirst())
    try:
      await ws.send($(%*{"type": "batch", "items": batch}))
    except WebSocketError:
      q.closed = true
      break

proc handleUserMessage(s: AppState, convId: int64, ws: WebSocket,
                        st: ChatTurnState, content: string) {.async, gcsafe.} =
  st.generating = true
  st.cancelled = false
  try:
    discard s.orchestrator.appendMessage(convId, none(int64), "user", content)
    logInfo("ws", "conversation " & $convId & " user message (" & $content.len & " chars)")
    try:
      let sess = await getOrCreateChatSession(s, convId)
      var history: seq[(string, string)] = @[]
      for (mid, parentId, role, msgContent, createdAt) in s.db.messagesForConversation(convId):
        if role == "reasoning":
          continue ## not a valid chat-completions role; kept in the DB only for display
        history.add((role, msgContent))
      logInfo("router", "sendTurn model=" & sess.model & " messages=" & $history.len)
      let queue = newTokenQueue()
      let senderFut = runSender(ws, queue)
      let onToken = proc(tok: string): Future[void] {.gcsafe.} =
        queue.push(%*{"type": "assistant_token", "content": tok})
        result = newFuture[void]("onToken")
        result.complete()
      let onReasoning = proc(tok: string): Future[void] {.gcsafe.} =
        queue.push(%*{"type": "reasoning_token", "content": tok})
        result = newFuture[void]("onReasoning")
        result.complete()
      let isCancelled = proc(): bool {.gcsafe.} =
        st.cancelled
      let reply = await sess.sendTurnStreaming(history, onToken, onReasoning, isCancelled)
      ## Generation is done, but the WebSocket sender may still be catching
      ## up on a backlog: close the queue and wait for it to drain so every
      ## token reaches the browser before the final assistant_message is
      ## sent (ordering matters for the UI), without having made llama.cpp
      ## wait for the network at any point above.
      closeQueue(queue)
      await senderFut
      if reply.content.len == 0 and not st.cancelled:
        ## An empty, non-cancelled reply means something went wrong
        ## upstream (router unreachable mid-stream, model crash/OOM, a
        ## malformed response, etc.) — don't silently store/show an empty
        ## assistant message, surface it as an actual error instead.
        let fallback = if reply.error.len > 0: reply.error
                       else: "model returned an empty reply — check server logs"
        let reason = routerAwareFailureReason(s, fallback)
        logError("ws", "conversation " & $convId & " got an EMPTY reply from the model: " & reason)
        await ws.send($(%*{"type": "error", "content": reason}))
      else:
        if reply.content.len == 0:
          logInfo("ws", "conversation " & $convId & " got an EMPTY reply from the model (cancelled=" & $st.cancelled & ")")
        else:
          logInfo("router", "sendTurn reply (" & $reply.content.len & " chars, " &
            $reply.reasoning.len & " reasoning char(s), cancelled=" & $st.cancelled & ")")
        if reply.reasoning.len > 0:
          discard s.orchestrator.appendMessage(convId, none(int64), "reasoning", reply.reasoning)
        discard s.orchestrator.appendMessage(convId, none(int64), "assistant", reply.content)
        await ws.send($(%*{"type": "assistant_message", "content": reply.content,
                           "reasoning": reply.reasoning, "cancelled": st.cancelled}))
      let newTitle = await maybeGenerateTitle(s, convId, sess, history)
      if newTitle.isSome:
        await ws.send($(%*{"type": "title_updated", "title": newTitle.get()}))
    except CatchableError as e:
      let reason = routerAwareFailureReason(s, e.msg)
      logError("ws", "conversation " & $convId & " chat turn failed: " & $e.name & ": " & e.msg)
      await ws.send($(%*{"type": "error", "content": reason}))
  finally:
    st.generating = false

proc wsChat*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let convId = parseInt(ctx.getPathParams("id")).int64
  var ws = await newWebSocket(ctx)
  let st = ChatTurnState(generating: false, cancelled: false)
  while ws.readyState == Open:
    try:
      let packet = await ws.receiveStrPacket()
      let node = parseJson(packet)
      let msgType = node{"type"}.getStr("")
      case msgType
      of "cancel_generation":
        if st.generating:
          st.cancelled = true
          logInfo("ws", "conversation " & $convId & " cancel requested")
        else:
          logInfo("ws", "conversation " & $convId & " cancel requested but nothing is generating")
      of "user_message":
        if st.generating:
          logInfo("ws", "conversation " & $convId & " rejected user message: a reply is already in progress")
          await ws.send($(%*{"type": "assistant_message", "content": "(a reply is already being generated — please wait)"}))
        else:
          let content = node{"content"}.getStr("")
          asyncCheck handleUserMessage(s, convId, ws, st, content)
      else:
        logInfo("ws", "conversation " & $convId & " unknown message type: " & msgType)
    except WebSocketError:
      break
    except CatchableError as e:
      logInfo("ws", "conversation " & $convId & " unexpected error: " & $e.name & ": " & e.msg)
      break
