## HTTP + WebSocket routes for the Cerisier web UI.
## Every page is a normal server-rendered full page load, except the chat
## page's WebSocket channel which live-updates in place.

import std/[asyncdispatch, json, strformat, options, strutils, tables, sequtils, deques, times, oids]
import prologue
import prologue/websocket
import ./layout
import ../db/database
import ../skills/skills
import ../formats/formats
import ../files/files
import ../llama/router_client
import ../llama/session
import ../llama/preset
import ../llama/process
import ../agent/conversation
import ../agent/prompt
import ../agent/subagent
import ../tools/registry
import ../tools/executor
import ../tools/builtin
import ../tools/runner_remote
import ../tools/toolcalls
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
    toolExecutor*: ToolExecutor
    pendingApprovals*: Table[int64, Future[void]] ## toolCallId -> resolved when approve/deny/kill lands
    presetsPath*: string
    pm*: ProcessManager ## router process supervisor, for status reporting in the UI
    lastLoadAttempt*: string ## "modelId at HH:mm:ss" of the most recent load attempt, for diagnostics
    companions*: CompanionRegistry ## connected client agents (cerisier-agent); shared with the executor
    dataDir*: string ## runtime data dir; uploads / generated files live under <dataDir>/files

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

proc escapeHtml(s: string): string =
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    else: result.add(c)

proc escapeAttr(s: string): string =
  ## For values placed inside a double-quoted HTML attribute.
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '"': result.add("&quot;")
    of '\'': result.add("&#39;")
    else: result.add(c)

# ---------------- Chat (the one live-updating page) ----------------

type
  MsgRow = (int64, string, string, string, string) ## (id, parent_id or "", role, content, created_at)

proc selectedAttr(cond: bool): string =
  if cond: " selected" else: ""

proc fileChipHtml(f: FileRow): string =
  let url = "/files/" & $f.id
  if f.mime.startsWith("image/"):
    result = "<a class=\"file-chip file-image\" href=\"" & url & "\" target=\"_blank\"><img src=\"" & url &
      "\" alt=\"" & escapeAttr(f.name) & "\"><span>" & escapeHtml(f.name) & "</span></a>"
  else:
    result = "<a class=\"file-chip\" href=\"" & url & "\" download=\"" & escapeAttr(f.name) &
      "\">&#128196; " & escapeHtml(f.name) & " (" & humanSize(f.size) & ")</a>"

proc attachmentsHtml(rows: seq[FileRow]): string =
  if rows.len == 0:
    return ""
  result = "<div class=\"attachments\">"
  for f in rows:
    result.add(fileChipHtml(f))
  result.add("</div>")

proc resultFileChipHtml(resultContent: string): string =
  ## A successful write_file result carries the created file; show a download
  ## chip next to the tool call.
  try:
    let f = parseJson(resultContent){"data", "file"}
    if f != nil and f.kind == JObject:
      let row: FileRow = (id: f{"id"}.getInt().int64, conversationId: 0'i64, messageId: 0'i64,
        name: f{"name"}.getStr(), storedName: "", mime: f{"mime"}.getStr(),
        size: f{"size"}.getInt().int64, origin: "generated")
      return attachmentsHtml(@[row])
  except CatchableError:
    discard
  ""

proc toolCallHtml(call: ParsedToolCall, resultContent: string): string =
  if call.malformed:
    return "<details class=\"tool-call result failed\"><summary>Tool call: malformed</summary><pre>" &
      escapeHtml(call.error) & "</pre></details>\n"
  var ok = false
  try:
    ok = parseJson(resultContent){"ok"}.getBool(false)
  except CatchableError:
    ok = false
  let cls = if ok: "succeeded" else: "failed"
  "<details class=\"tool-call result " & cls & "\"><summary>Tool call: " & escapeHtml(call.name) &
    "</summary><pre>" & escapeHtml(call.argsJson) & "</pre><pre>" & escapeHtml(resultContent) &
    "</pre></details>\n"

proc renderMessageList(s: AppState, msgs: seq[MsgRow], children: Table[int64, seq[MsgRow]]): string {.gcsafe.}

proc renderSubAgent(s: AppState, root: MsgRow, children: Table[int64, seq[MsgRow]],
                    resultContent: string): string {.gcsafe.} =
  ## A sub-agent's task is a child `user` message of the assistant message that
  ## called spawn_subagent; everything it said/did hangs beneath that task row.
  let task = root[3]
  var ok = false
  try:
    ok = parseJson(resultContent){"ok"}.getBool(false)
  except CatchableError:
    ok = false
  let short = if task.len > 90: trimToUtf8(task[0 ..< 90]) & "…" else: task
  var inner = ""
  if children.hasKey(root[0]):
    inner = renderMessageList(s, children[root[0]], children)
  let statusCls = if ok: "ok" else: "bad"
  let statusTxt = if ok: "done" else: "failed"
  result = "<details class=\"subagent\"><summary><span class=\"subagent-label\">Sub-agent: </span>" &
    "<span class=\"subagent-task\">" & escapeHtml(short) & "</span><span class=\"subagent-status " &
    statusCls & "\">" & statusTxt & "</span></summary><div class=\"subagent-body\"><div class=\"msg user\">" &
    escapeHtml(task) & "</div>" & inner & "</div></details>\n"

proc renderMessageList(s: AppState, msgs: seq[MsgRow], children: Table[int64, seq[MsgRow]]): string {.gcsafe.} =
  ## Renders sibling messages of one level (the top level, or one sub-agent).
  ## Assistant text is emitted raw (escaped) inside `data-md` blocks; the
  ## browser turns it into Markdown/code/math (see web/static/rich.js).
  result = ""
  var i = 0
  while i < msgs.len:
    let (id, _, role, content, _) = msgs[i]
    if role == "reasoning":
      result.add("<details class=\"reasoning\"><summary>Reasoning</summary><div>" & escapeHtml(content) & "</div></details>\n")
      inc i
    elif role == "assistant":
      let calls = parseToolCalls(content)
      let visible = stripToolCalls(content)
      if visible.len > 0:
        result.add("<div class=\"msg assistant md\" data-md>" & escapeHtml(visible) & "</div>\n")
      inc i
      var subRoots: seq[MsgRow] = @[]
      if children.hasKey(id):
        for k in children[id]:
          if k[2] == "user":
            subRoots.add(k)
      var subIdx = 0
      ## Tool call results are separate `tool`-role rows appended right
      ## after this assistant message, one per parsed call, in order.
      for call in calls:
        var resultContent = ""
        if i < msgs.len and msgs[i][2] == "tool":
          resultContent = msgs[i][3]
          inc i
        result.add(toolCallHtml(call, resultContent))
        if not call.malformed:
          if call.name == subagentToolName and subIdx < subRoots.len:
            result.add(renderSubAgent(s, subRoots[subIdx], children, resultContent))
            inc subIdx
          result.add(resultFileChipHtml(resultContent))
    elif role == "user":
      result.add("<div class=\"msg user\">" & escapeHtml(content) &
        attachmentsHtml(s.db.listFilesForMessage(id)) & "</div>\n")
      inc i
    else:
      result.add("<div class=\"msg " & role & "\">" & escapeHtml(content) & "</div>\n")
      inc i

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

  ## Top-level messages vs. messages that hang under another one (sub-agents).
  var top: seq[MsgRow] = @[]
  var children = initTable[int64, seq[MsgRow]]()
  for m in s.db.messagesForConversation(currentId):
    if m[1].len == 0:
      top.add(m)
    else:
      let pid = parseBiggestInt(m[1]).int64
      if not children.hasKey(pid):
        children[pid] = @[]
      children[pid].add(m)
  let log = renderMessageList(s, top, children)

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

  let toolTarget = s.db.getConversationToolTarget(currentId)
  let agentCount = if s.companions != nil: s.companions.connectedCount() else: 0
  let agentCls = if agentCount > 0: "ok" else: ""
  let agentText = if agentCount > 0: "client agent connected" else: "no client agent connected"
  let todosJson = $todosToJson(s.db.listTodos(currentId))
  ## Embedded in a <script>: make sure model-written text can't close the tag.
  let formatsScript = formatsJson(s.db).replace("<", "\\u003c")
  let selDefault = selectedAttr(toolTarget != "server" and toolTarget != "client")
  let selServer = selectedAttr(toolTarget == "server")
  let selClient = selectedAttr(toolTarget == "client")

  let body = &"""
  {routerStatusBanner(s)}
  <div id="chat-header">
    <h1 id="chat-title">{escapeHtml(title)}</h1>
    <label for="model-select">Model:</label>
    <select id="model-select">{modelOptions}</select>
    <label for="tool-target-select">Run tools on:</label>
    <select id="tool-target-select" title="Where tool calls execute: each tool's own setting, the server, or the client machine (needs cerisier-agent running there)">
      <option value="default"{selDefault}>Per tool</option>
      <option value="server"{selServer}>Server</option>
      <option value="client"{selClient}>Client</option>
    </select>
    <span id="agent-status" class="{agentCls}">{agentText}</span>
  </div>
  <div id="chat-log">{log}</div>
  <div id="chat-compose">
    <div id="todo-widget" data-todos="{escapeAttr(todosJson)}" style="display:none"></div>
    <div id="attachments"></div>
    <div id="compose-note"></div>
    <form id="chat-form">
      <button type="button" id="attach-btn" title="Attach files">&#128206;</button>
      <input type="file" id="file-input" multiple hidden>
      <textarea id="chat-input" rows="1" placeholder="Message… (Enter to send, Shift+Enter for a new line)" autocomplete="off"></textarea>
      <button type="submit">Send</button>
      <button type="button" id="stop-btn" style="display:none">Stop</button>
    </form>
  </div>
  <script>window.CERISIER_FORMATS = {formatsScript};</script>
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
    rows.add(&"<tr><td><a href=\"/chat/{id}\">{escapeHtml(title)}</a></td><td>{createdAt}</td></tr>\n")
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



# ---------------- Tools (registry management: register/edit/delete tool
# manifests. Runtime approval/deny/kill of individual tool calls happens
# inline in the chat UI, never here.) ----------------

proc toolsPage*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  var rows = ""
  for t in s.toolRegistry.tools:
    rows.add(&"""<tr><td>{t.name}</td><td>{t.description}</td><td>{t.kind}</td><td>{t.location}</td><td><code>{t.entrypoint}</code></td><td>{t.permission}</td>
      <td><a href="/tools/edit/{t.name}">Edit</a></td>
      <td><form class="inline" method="post" action="/tools/delete"><input type="hidden" name="name" value="{t.name}"><button>Delete</button></form></td></tr>""")
  let body = &"""<h1>Tools</h1>
  <p>Register/edit the scripts and executables available to the agent. Approving, denying, or killing an individual tool call happens inline in the chat, not here.</p>
  <table><tr><th>Name</th><th>Description</th><th>Kind</th><th>Location</th><th>Entrypoint</th><th>Permission</th><th></th><th></th></tr>{rows}</table>
  <h2>New tool</h2>
  <form method="post" action="/tools/new">
    <p>Name: <input name="name"></p>
    <p>Description: <input name="description" size="60"></p>
    <p>Kind: <select name="kind"><option value="shell">shell</option><option value="python">python</option><option value="nim-binary">nim-binary</option></select></p>
    <p>Location: <select name="location"><option value="local">local</option><option value="remote">remote</option></select></p>
    <p>Entrypoint: <input name="entrypoint" size="60"></p>
    <p>Input schema (JSON): <textarea name="input_schema" rows="3" cols="60">{{}}</textarea></p>
    <p>Output schema (JSON): <textarea name="output_schema" rows="3" cols="60">{{}}</textarea></p>
    <p>Timeout (ms): <input name="timeout_ms" value="30000"></p>
    <p>Permission: <select name="permission"><option value="ask">ask</option><option value="auto">auto</option><option value="deny">deny</option></select></p>
    <p><button type="submit">Save</button></p>
  </form>"""
  resp htmlResponse(page("Tools", "/tools", body))

proc toolsEditGet*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let name = ctx.getPathParams("name")
  var m: ToolManifest
  try:
    m = s.toolRegistry.find(name)
  except KeyError:
    resp redirect("/tools")
    return
  let body = &"""<h1>Edit tool: {m.name}</h1>
  <form method="post" action="/tools/edit">
    <input type="hidden" name="orig_name" value="{m.name}">
    <p>Name: <input name="name" value="{m.name}"></p>
    <p>Description: <input name="description" value="{m.description}" size="60"></p>
    <p>Kind:
      <select name="kind">
        <option value="shell" {(if m.kind == tkShell: "selected" else: "")}>shell</option>
        <option value="python" {(if m.kind == tkPython: "selected" else: "")}>python</option>
        <option value="nim-binary" {(if m.kind == tkNimBinary: "selected" else: "")}>nim-binary</option>
      </select></p>
    <p>Location:
      <select name="location">
        <option value="local" {(if m.location == tlLocal: "selected" else: "")}>local</option>
        <option value="remote" {(if m.location == tlRemote: "selected" else: "")}>remote</option>
      </select></p>
    <p>Entrypoint: <input name="entrypoint" value="{m.entrypoint}" size="60"></p>
    <p>Input schema (JSON): <textarea name="input_schema" rows="3" cols="60">{m.inputSchema}</textarea></p>
    <p>Output schema (JSON): <textarea name="output_schema" rows="3" cols="60">{m.outputSchema}</textarea></p>
    <p>Timeout (ms): <input name="timeout_ms" value="{m.timeoutMs}"></p>
    <p>Permission:
      <select name="permission">
        <option value="ask" {(if m.permission == ptAsk: "selected" else: "")}>ask</option>
        <option value="auto" {(if m.permission == ptAuto: "selected" else: "")}>auto</option>
        <option value="deny" {(if m.permission == ptDeny: "selected" else: "")}>deny</option>
      </select></p>
    <p><button type="submit">Save</button></p>
  </form>"""
  resp htmlResponse(page("Edit tool", "/tools", body))

proc manifestFromForm(ctx: Context): ToolManifest =
  ToolManifest(
    name: ctx.getFormParams("name").strip(),
    description: ctx.getFormParams("description"),
    kind: parseEnum[ToolKind](ctx.getFormParams("kind")),
    location: parseEnum[ToolLocation](ctx.getFormParams("location")),
    entrypoint: ctx.getFormParams("entrypoint"),
    inputSchema: ctx.getFormParams("input_schema"),
    outputSchema: ctx.getFormParams("output_schema"),
    timeoutMs: parseInt(ctx.getFormParams("timeout_ms")),
    permission: parseEnum[ToolPermission](ctx.getFormParams("permission")),
  )

proc toolsNewPost*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let m = manifestFromForm(ctx)
  if m.name.len > 0:
    s.toolRegistry.saveManifest(m)
  resp redirect("/tools")

proc toolsEditPost*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let origName = ctx.getFormParams("orig_name")
  let m = manifestFromForm(ctx)
  if m.name.len > 0:
    if origName.len > 0 and origName != m.name:
      s.toolRegistry.deleteManifest(origName)
    s.toolRegistry.saveManifest(m)
  resp redirect("/tools")

proc toolsDeletePost*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let name = ctx.getFormParams("name")
  s.toolRegistry.deleteManifest(name)
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
                         history: seq[ChatMsg]): Future[Option[string]] {.async.} =
  ## After a few messages, ask the model for a short topic title and store
  ## it, replacing the default "New conversation" placeholder.
  if history.len < titleGenThreshold:
    return none(string)
  if s.db.getConversationTitle(convId) != "New conversation":
    return none(string)
  try:
    var msgs: seq[ChatMsg] = @[]
    for m in history:
      msgs.add(chatMsg(m.role, m.content))
    msgs.add(chatMsg("user", "In 3-6 words, give a short topic title for this " &
                             "conversation. Reply with only the title, no punctuation."))
    let rawTitle = await sess.sendTurn(msgs)
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
    pendingIds: seq[int64] ## tool calls waiting for an approve/deny click (denied if the turn is cancelled)

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

# ---------------- Agent loop helpers ----------------

proc resolveApproval(s: AppState, id: int64) =
  ## Wakes whoever is awaiting approval of this tool call. The entry is removed
  ## first, so a late/duplicate approve for the same id can't act twice.
  if s.pendingApprovals.hasKey(id):
    let fut = s.pendingApprovals[id]
    s.pendingApprovals.del(id)
    if not fut.finished:
      fut.complete()

proc makeMainApproval(s: AppState, st: ChatTurnState, ws: WebSocket): ApprovalHook =
  ## Approval prompt for tool calls issued by the main chat: the pending card
  ## goes straight out over the WebSocket; the future resolves when the
  ## approve/deny/cancel handler in `wsChat` calls `resolveApproval`.
  proc ask(toolCallId: int64, toolName, argsJson, target: string): Future[void] {.gcsafe.} =
    let fut = newFuture[void]("pendingApproval")
    s.pendingApprovals[toolCallId] = fut
    st.pendingIds.add(toolCallId)
    asyncCheck ws.send($(%*{"type": "tool_call_pending", "id": toolCallId, "name": toolName,
                            "args": argsJson, "target": target}))
    result = fut
  result = ask

proc makeSubAgentHooks(s: AppState, st: ChatTurnState, queue: TokenQueue): SubAgentHooks =
  ## Everything a sub-agent reports goes through `queue` so its events stay in
  ## order with its streamed tokens (the queue is drained by `runSender`).
  proc emitEvent(ev: JsonNode) {.gcsafe.} =
    queue.push(ev)
  proc askFn(toolCallId: int64, toolName, argsJson, target: string): Future[void] {.gcsafe.} =
    let fut = newFuture[void]("subAgentApproval")
    s.pendingApprovals[toolCallId] = fut
    st.pendingIds.add(toolCallId)
    queue.push(%*{"type": "tool_call_pending", "id": toolCallId, "name": toolName,
                  "args": argsJson, "target": target})
    result = fut
  proc cancelledFn(): bool {.gcsafe.} =
    st.cancelled
  result = SubAgentHooks(emit: emitEvent, askApproval: askFn, isCancelled: cancelledFn)

proc runBuiltinCall(s: AppState, convId, assistantMsgId: int64, ws: WebSocket,
                    toolName, argsJson: string): Future[string] {.async, gcsafe.} =
  ## Runs a built-in tool (todo_write, write_file, read_file, list_files),
  ## records it like any other tool call and returns the result JSON.
  let env = BuiltinEnv(db: s.db, dataDir: s.dataDir, convId: convId, messageId: assistantMsgId)
  let res = runBuiltin(env, toolName, argsJson)
  let status = if res.ok: $tcsSucceeded else: $tcsFailed
  let tcId = s.db.createToolCall(assistantMsgId, toolName, $etServer, argsJson)
  s.db.setToolCallResult(tcId, status, res.resultJson)
  for ev in res.events:
    await ws.send($ev)
  await ws.send($(%*{"type": "tool_call_result", "id": tcId, "name": toolName, "args": argsJson,
                     "status": status, "result": res.resultJson}))
  result = res.resultJson

proc runSubAgentCall(s: AppState, convId, assistantMsgId: int64, ws: WebSocket, st: ChatTurnState,
                     sess: LlamaSession, argsJson: string): Future[string] {.async, gcsafe.} =
  ## Executes `spawn_subagent`: runs the sub-agent to completion (streaming its
  ## progress into the chat) and returns the result JSON for the parent.
  let tcId = s.db.createToolCall(assistantMsgId, subagentToolName, $etServer, argsJson)
  var outJson = ""
  var status = $tcsFailed
  let verr = validateBuiltinArgs(subagentToolName, argsJson)
  if verr.len > 0:
    outJson = $(%*{"ok": false, "error": verr})
  else:
    let a = parseJson(argsJson)
    var allow: seq[string] = @[]
    let toolNames = a{"tools"}
    if toolNames != nil and toolNames.kind == JArray:
      for t in toolNames:
        allow.add(t.getStr())
    ## Size the child session from the model's preset rather than the chat
    ## session's conservative default.
    var ctxSize = sess.ctxSize
    let presetRow = database.getModelPreset(s.db, sess.model)
    if presetRow.isSome:
      ctxSize = presetRow.get().ctxSize
    let queue = newTokenQueue()
    let senderFut = runSender(ws, queue)
    let env = SubAgentEnv(db: s.db, router: s.router, registry: s.toolRegistry,
      executor: s.toolExecutor, dataDir: s.dataDir, convId: convId,
      parentMessageId: assistantMsgId, model: sess.model, ctxSize: ctxSize,
      hooks: makeSubAgentHooks(s, st, queue))
    var res = SubAgentResult(ok: false, report: "", error: "", rounds: 0)
    try:
      res = await runSubAgent(env, a["task"].getStr(), a{"context"}.getStr(""), allow)
    except CatchableError as e:
      res.error = e.msg
      logError("subagent", "crashed: " & $e.name & ": " & e.msg)
    closeQueue(queue)
    await senderFut
    if res.ok:
      status = $tcsSucceeded
      outJson = $(%*{"ok": true, "data": {"report": res.report, "rounds": res.rounds}})
    else:
      let reason = if res.error.len > 0: res.error else: "the sub-agent failed"
      outJson = $(%*{"ok": false, "error": reason})
  s.db.setToolCallResult(tcId, status, outJson)
  await ws.send($(%*{"type": "tool_call_result", "id": tcId, "name": subagentToolName,
                     "args": argsJson, "status": status, "result": outJson}))
  result = outJson

proc buildHistory(s: AppState, convId: int64, visionOk: bool): seq[ChatMsg] =
  ## The main model's context: system prompt (tools, formatting, todo + file
  ## snapshot) plus the *top-level* messages. Messages that belong to a
  ## sub-agent (they have a parent) are deliberately left out — keeping them
  ## out of this context is the whole point of sub-agents.
  result = @[]
  let sys = buildSystemPrompt(s.db, s.toolRegistry, convId)
  if sys.len > 0:
    result.add(chatMsg("system", sys))
  for (mid, parentId, role, msgContent, createdAt) in s.db.messagesForConversation(convId):
    if parentId.len > 0:
      continue
    if role == "reasoning":
      continue ## not a valid chat-completions role; kept in the DB only for display
    if role == "user":
      let att = describeAttachments(s.db, s.dataDir, mid, visionOk)
      if att.note.len > 0 or att.images.len > 0:
        result.add(chatMsg(role, msgContent & att.note, att.images))
        continue
    result.add(chatMsg(role, msgContent))

proc handleUserMessage(s: AppState, convId: int64, ws: WebSocket,
                        st: ChatTurnState, content: string, fileIds: seq[int64]) {.async, gcsafe.} =
  st.generating = true
  st.cancelled = false
  try:
    let userMsgId = s.orchestrator.appendMessage(convId, none(int64), "user", content)
    for fid in fileIds:
      s.db.attachFileToMessage(fid, userMsgId, convId)
    logInfo("ws", "conversation " & $convId & " user message (" & $content.len & " chars, " &
      $fileIds.len & " attachment(s))")
    try:
      let sess = await getOrCreateChatSession(s, convId)

      ## Only ask the router whether the model can see images when there are any.
      var visionOk = false
      var hasImages = false
      for f in s.db.listFilesForConversation(convId):
        if isVisionImage(f.mime):
          hasImages = true
          break
      if hasImages:
        try:
          let models = await s.router.listModels()
          for m in models:
            if m.id == sess.model and m.supportsVision:
              visionOk = true
        except CatchableError as e:
          logInfo("router", "could not check vision support: " & e.msg)

      var finalReply: StreamingReply
      var lastHistoryForTitle: seq[ChatMsg] = @[]
      let askMain = makeMainApproval(s, st, ws)

      while true:
        let history = buildHistory(s, convId, visionOk)
        lastHistoryForTitle = history
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
        closeQueue(queue)
        await senderFut
        finalReply = reply

        if reply.reasoning.len > 0:
          discard s.orchestrator.appendMessage(convId, none(int64), "reasoning", reply.reasoning)

        let calls = parseToolCalls(reply.content)
        if calls.len == 0 or st.cancelled:
          var visible = stripToolCalls(reply.content)
          if visible.len > 0:
            discard s.orchestrator.appendMessage(convId, none(int64), "assistant", visible)
          finalReply = StreamingReply(content: visible, reasoning: reply.reasoning, error: reply.error)
          break

        let assistantMsgId = s.orchestrator.appendMessage(convId, none(int64), "assistant", reply.content)
        for call in calls:
          var resultJson = ""
          if call.malformed:
            resultJson = $(%*{"ok": false, "error": call.error})
          elif st.cancelled:
            resultJson = $(%*{"ok": false, "error": "cancelled"})
          elif call.name == subagentToolName:
            resultJson = await runSubAgentCall(s, convId, assistantMsgId, ws, st, sess, call.argsJson)
          elif isBuiltin(call.name):
            resultJson = await runBuiltinCall(s, convId, assistantMsgId, ws, call.name, call.argsJson)
          else:
            let d = await s.toolExecutor.dispatchToolCall(convId, assistantMsgId, call.name,
                                                           call.argsJson, askMain)
            resultJson = if d.resultJson.len > 0: d.resultJson else: $(%*{"ok": false, "error": d.status})
            await ws.send($(%*{"type": "tool_call_result", "id": d.id, "name": call.name,
                               "args": call.argsJson, "status": d.status, "result": d.resultJson}))
          discard s.orchestrator.appendMessage(convId, none(int64), "tool", resultJson)
        if st.cancelled:
          finalReply = StreamingReply(content: "", reasoning: "", error: "")
          break

      if finalReply.content.len == 0 and not st.cancelled:
        ## An empty, non-cancelled reply means something went wrong
        ## upstream (router unreachable mid-stream, model crash/OOM, a
        ## malformed response, etc.) — don't silently store/show an empty
        ## assistant message, surface it as an actual error instead.
        let fallback = if finalReply.error.len > 0: finalReply.error
                       else: "model returned an empty reply — check server logs"
        let reason = routerAwareFailureReason(s, fallback)
        logError("ws", "conversation " & $convId & " got an EMPTY reply from the model: " & reason)
        await ws.send($(%*{"type": "error", "content": reason}))
      else:
        if finalReply.content.len == 0:
          logInfo("ws", "conversation " & $convId & " got an EMPTY reply from the model (cancelled=" & $st.cancelled & ")")
        else:
          logInfo("router", "sendTurn reply (" & $finalReply.content.len & " chars, " &
            $finalReply.reasoning.len & " reasoning char(s), cancelled=" & $st.cancelled & ")")
        await ws.send($(%*{"type": "assistant_message", "content": finalReply.content,
                           "reasoning": finalReply.reasoning, "cancelled": st.cancelled}))
      let newTitle = await maybeGenerateTitle(s, convId, sess, lastHistoryForTitle)
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
  let st = ChatTurnState(generating: false, cancelled: false, pendingIds: @[])
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
          ## A turn that is waiting for an approve/deny click would otherwise
          ## never notice the cancellation: deny whatever is pending.
          let waiting = st.pendingIds
          st.pendingIds = @[]
          for pendingId in waiting:
            s.toolExecutor.deny(pendingId)
            resolveApproval(s, pendingId)
        else:
          logInfo("ws", "conversation " & $convId & " cancel requested but nothing is generating")
      of "user_message":
        if st.generating:
          logInfo("ws", "conversation " & $convId & " rejected user message: a reply is already in progress")
          await ws.send($(%*{"type": "assistant_message", "content": "(a reply is already being generated — please wait)"}))
        else:
          let content = node{"content"}.getStr("")
          var fileIds: seq[int64] = @[]
          let fileNodes = node{"files"}
          if fileNodes != nil and fileNodes.kind == JArray:
            for fnode in fileNodes:
              let fid = fnode.getInt(0).int64
              if fid != 0:
                fileIds.add(fid)
          if content.strip().len > 0 or fileIds.len > 0:
            asyncCheck handleUserMessage(s, convId, ws, st, content, fileIds)
      of "tool_call_approve":
        let id = node{"id"}.getInt(0).int64
        let always = node{"always"}.getBool(false)
        ## Only act on calls that are actually waiting for an answer: a replayed
        ## or duplicated message must never re-run a tool.
        if id != 0 and s.pendingApprovals.hasKey(id):
          st.pendingIds.keepItIf(it != id)
          if always:
            let (_, _, toolName, _) = s.db.getToolCall(id)
            s.toolExecutor.setSessionPermission(convId, toolName, ptAuto)
          s.toolExecutor.approve(id)
          let (_, _, toolName, argsJson) = s.db.getToolCall(id)
          asyncCheck (proc() {.async, gcsafe.} =
            await s.toolExecutor.execute(id, toolName, argsJson)
            resolveApproval(s, id)
          )()
      of "tool_call_deny":
        let id = node{"id"}.getInt(0).int64
        let always = node{"always"}.getBool(false)
        if id != 0 and s.pendingApprovals.hasKey(id):
          st.pendingIds.keepItIf(it != id)
          if always:
            let (_, _, toolName, _) = s.db.getToolCall(id)
            s.toolExecutor.setSessionPermission(convId, toolName, ptDeny)
          s.toolExecutor.deny(id)
          resolveApproval(s, id)
      of "tool_call_kill":
        let id = node{"id"}.getInt(0).int64
        if id != 0:
          s.toolExecutor.killToolCall(id)
      else:
        logInfo("ws", "conversation " & $convId & " unknown message type: " & msgType)
    except WebSocketError:
      break
    except CatchableError as e:
      logInfo("ws", "conversation " & $convId & " unexpected error: " & $e.name & ": " & e.msg)
      break

# ---------------- Chat settings, uploads, downloads ----------------

proc chatToolTargetPost*(ctx: Context) {.async, gcsafe.} =
  ## "Run tools on": default (per tool) | server | client.
  let s = getState()
  try:
    let convId = parseBiggestInt(ctx.getPathParams("id")).int64
    let target = parseJson(ctx.request.body){"target"}.getStr("")
    discard parseEnum[ToolTargetPref](target) ## raises ValueError for anything else
    s.db.setConversationToolTarget(convId, target)
    logInfo("routes", "conversation " & $convId & " runs tools on: " & target)
    resp jsonResponse(%*{"success": true})
  except CatchableError as e:
    resp jsonResponse(%*{"success": false, "error": "invalid tool location: " & e.msg})

proc todosClearPost*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  try:
    let convId = parseBiggestInt(ctx.getPathParams("id")).int64
    s.db.clearTodos(convId)
    resp jsonResponse(%*{"success": true})
  except CatchableError as e:
    resp jsonResponse(%*{"success": false, "error": e.msg})

proc uploadPost*(ctx: Context) {.async, gcsafe.} =
  ## Raw-body upload (the browser POSTs the File itself; name/type travel in
  ## the query string) so binary data never goes through form/JSON encoding.
  let s = getState()
  try:
    let convId = parseBiggestInt(ctx.getPathParams("id")).int64
    let name = ctx.getQueryParams("name", "file")
    let mime = ctx.getQueryParams("type", "")
    let data = ctx.request.body
    if data.len == 0:
      resp jsonResponse(%*{"success": false, "error": "empty upload"})
      return
    if data.len > maxUploadBytes:
      resp jsonResponse(%*{"success": false, "error": "file too large (limit " & humanSize(maxUploadBytes.int64) & ")"})
      return
    let rec = saveFileBytes(s.db, s.dataDir, convId, name, mime, "upload", data)
    logInfo("routes", "conversation " & $convId & " upload '" & rec.name & "' (" & humanSize(rec.size) & ")")
    resp jsonResponse(%*{"success": true, "file": fileToJson(rec)})
  except CatchableError as e:
    logError("routes", "upload failed: " & $e.name & ": " & e.msg)
    resp jsonResponse(%*{"success": false, "error": e.msg})

proc fileGet*(ctx: Context) {.async, gcsafe.} =
  ## Files are addressed by database id; the on-disk name comes from the
  ## database, never from the request.
  let s = getState()
  var fid: int64
  try:
    fid = parseBiggestInt(ctx.getPathParams("fid")).int64
  except ValueError:
    resp plainTextResponse("bad file id", Http400)
    return
  let rec = s.db.getFile(fid)
  if rec.isNone:
    resp plainTextResponse("file not found", Http404)
    return
  let f = rec.get()
  await staticFileResponse(ctx, f.storedName, convDir(s.dataDir, f.conversationId))

# ---------------- WebSocket: client agents ----------------

proc makeCompanionSender(ws: WebSocket): CompanionSender =
  result = proc(msg: string): Future[void] {.gcsafe.} =
    ws.send(msg)

proc wsAgent*(ctx: Context) {.async, gcsafe.} =
  ## A cerisier-agent running on the client machine connects here, advertises
  ## its tools (`hello`), then receives `run_tool` jobs and returns
  ## `tool_result` messages (see tools/runner_remote.nim for the protocol).
  let s = getState()
  var ws = await newWebSocket(ctx)
  let companionId = $genOid()
  logInfo("ws", "client agent connected: " & companionId)
  while ws.readyState == Open:
    try:
      let packet = await ws.receiveStrPacket()
      let node = parseJson(packet)
      case node{"type"}.getStr("")
      of "hello":
        var tools: seq[ToolManifest] = @[]
        let arr = node{"tools"}
        if arr != nil and arr.kind == JArray:
          for t in arr:
            tools.add(ToolManifest(name: t{"name"}.getStr(""), description: t{"description"}.getStr("")))
        s.companions.register(companionId, tools)
        s.companions.registerSender(companionId, makeCompanionSender(ws))
        s.companions.names[companionId] = node{"name"}.getStr("agent")
        logInfo("ws", "client agent '" & node{"name"}.getStr("agent") & "' advertises " & $tools.len & " tool(s)")
      of "tool_result":
        let (jobId, jobResult) = parseResult(packet)
        if jobId.len > 0:
          s.companions.submitResult(jobId, jobResult)
      else:
        discard
    except WebSocketError:
      break
    except CatchableError as e:
      logInfo("ws", "client agent " & companionId & " error: " & $e.name & ": " & e.msg)
      break
  s.companions.unregister(companionId)
  logInfo("ws", "client agent disconnected: " & companionId)
