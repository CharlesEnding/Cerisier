## HTTP + WebSocket routes for the Cerisier web UI.
## Every page is a normal server-rendered full page load, except the chat
## page's WebSocket channel which live-updates in place.

import std/[asyncdispatch, json, strformat, options, strutils, tables, sequtils, deques, os]
import prologue
import prologue/websocket
import ./layout
import ../config
import ../db/database
import ../skills/skills
import ../formats/formats
import ../files/files
import ../api/client
import ../api/session
import ../agent/conversation
import ../agent/hooks
import ../agent/loop
import ../tools/registry
import ../tools/executor
import ../tools/builtin
import ../tools/toolcalls
import ../log
import ../../common/types

type
  AppState* = ref object
    cfg*: config.Config
    db*: Database
    api*: ApiClient
    orchestrator*: ConversationOrchestrator
    staticDir*: string
    chatSessions*: Table[int64, ChatSession] ## one live session per conversation, lazily created
    toolRegistry*: ToolRegistry
    toolExecutor*: ToolExecutor
    loop*: LoopEnv
    pendingApprovals*: Table[int64, Future[void]] ## toolCallId -> resolved when approve/deny/kill lands
    pendingEvents*: Table[int64, JsonNode] ## toolCallId -> its `tool_call_pending` event, re-sent when a browser reconnects
    dataDir*: string ## runtime data dir; uploads / generated files live under <dataDir>/files

var state*: AppState

proc getState*(): AppState {.gcsafe.} =
  {.cast(gcsafe).}:
    result = state

proc staticAsset*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let filename = ctx.getPathParams("file")
  await staticFileResponse(ctx, filename, s.staticDir)

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

proc backendStatusBanner(s: AppState): Future[string] {.async.} =
  ## Shown on the chat and models pages when the backend can't be reached.
  let err = await s.api.probe()
  if err.len == 0:
    return ""
  result = "<div class=\"router-banner\">Model backend unreachable (" & escapeHtml(s.cfg.apiUrl) &
    "): " & escapeHtml(err) & "</div>"

proc availableModels*(s: AppState): Future[seq[ModelEntry]] {.async.} =
  ## The configured models; when none are configured, whatever the backend
  ## lists, with default limits.
  if s.cfg.models.len > 0:
    return s.cfg.models
  result = @[]
  for m in await s.api.listModels():
    result.add(s.cfg.findModel(m.id))

proc findAvailableModel*(s: AppState, name: string): Future[ModelEntry] {.async.} =
  for m in await availableModels(s):
    if m.name == name:
      return m
  raise newException(CatchableError, "unknown model: " & name)

# ---------------- Chat (the one live-updating page) ----------------

type
  MsgRow = (int64, string, string, string, string) ## (id, parent_id or "", role, content, created_at)

const effortLevels = ["low", "medium", "high"] ## "" (model default) is always allowed

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

const toolTargetArg = {
  "read_local_file": "path", "write_local_file": "path", "replace_text": "path",
  "list_dir": "path", "render_tree": "path", "search_files": "path",
  "read_file": "name", "write_file": "name", "write_tmp_file": "name", "check_installed": "name",
  "search_web": "query", "search_github": "query", "search_steam": "query",
  "search_youtube": "query", "read_webpage": "url",
  "list_python_packages": "names"}.toTable

proc toolTarget(call: ParsedToolCall): string =
  ## The argument shown after the tool name in the summary line.
  if call.name notin toolTargetArg:
    return ""
  try:
    let node = parseJson(call.argsJson){toolTargetArg[call.name]}
    var p = node.getStr()
    if node != nil and node.kind == JArray:
      var parts: seq[string]
      for e in node: parts.add(e.getStr())
      p = parts.join(", ")
    if p.len > 0: return " " & p
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
  let cls = if resultContent.len == 0: "awaiting" elif ok: "succeeded" else: "failed"
  let openAttr = if cls == "failed": " open" else: ""
  ## The args <pre> is tagged so the front-end can turn a replace_text call's
  ## args into a coloured diff on reload (see toolDiffHtml in web/static/app.js).
  "<details class=\"tool-call result " & cls & "\"" & openAttr & " data-tool-name=\"" & escapeAttr(call.name) &
    "\"><summary>Tool call: " & escapeHtml(call.name & toolTarget(call)) &
    "</summary><pre class=\"tool-args\">" & escapeHtml(call.argsJson) & "</pre><pre>" & escapeHtml(resultContent) &
    "</pre></details>\n"

proc timeHtml(createdAt: string, extraClass = ""): string =
  ## created_at is UTC; app.js shows it in the browser's local time.
  if createdAt.len == 0:
    return ""
  let iso = createdAt.replace(' ', 'T') & "Z"
  "<time class=\"msg-time " & extraClass & "\" datetime=\"" & escapeAttr(iso) & "\"></time>"

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
    let (id, _, role, content, createdAt) = msgs[i]
    if role == "reasoning":
      result.add("<details class=\"reasoning\"><summary>Reasoning</summary><div>" & escapeHtml(content) & "</div></details>\n")
      inc i
    elif role == "assistant":
      let calls = parseToolCalls(content, s.toolRegistry)
      let visible = stripToolCalls(content)
      if visible.len > 0:
        result.add("<div class=\"msg assistant md\" data-md>" & escapeHtml(visible) & "</div>\n" &
          timeHtml(createdAt, "assistant-time"))
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
        attachmentsHtml(s.db.listFilesForMessage(id)) & timeHtml(createdAt) & "</div>\n")
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
  var ctxUsed = 0
  var ctxMax = 0
  try:
    let models = await availableModels(s)
    if s.chatSessions.hasKey(currentId):
      let live = s.chatSessions[currentId]
      currentModel = live.model
      ctxUsed = live.promptTokens + live.completionTokens
    elif models.len > 0:
      currentModel = models[0].name
    for m in models:
      if m.name == currentModel:
        ctxMax = m.maxTokens
      let selected = if m.name == currentModel: " selected" else: ""
      modelOptions.add(&"<option value=\"{escapeAttr(m.name)}\"{selected}>{escapeHtml(m.displayName)}</option>")
  except CatchableError as e:
    logError("api", "listing models failed: " & e.msg)
  let banner = await backendStatusBanner(s)
  let currentEffort = s.db.getConversationEffort(currentId)
  var effortOptions = "<option value=\"\"" & (if currentEffort.len == 0: " selected" else: "") & ">default</option>"
  for lvl in effortLevels:
    let selected = if lvl == currentEffort: " selected" else: ""
    effortOptions.add(&"<option value=\"{lvl}\"{selected}>{lvl}</option>")

  let todosJson = $todosToJson(s.db.listTodos(currentId))
  let wd = s.db.getConversationWorkingDir(currentId)
  ## Embedded in a <script>: make sure model-written text can't close the tag.
  let formatsScript = formatsJson(s.db).replace("<", "\\u003c")

  let body = &"""
  {banner}
  <div id="chat-header">
    <h1 id="chat-title">{escapeHtml(title)}</h1>
    <label for="model-select">Model:</label>
    <select id="model-select">{modelOptions}</select>
    <label for="effort-select">Effort:</label>
    <select id="effort-select" title="Thinking effort sent to the model (default = the model's configured value)">{effortOptions}</select>
    <span id="ctx-meter" data-used="{ctxUsed}" data-ctx="{ctxMax}" title="Tokens in context (last prompt + reply) / context window"></span>
    <label for="workdir-input" id="workdir-label">Working dir:</label>
    <input id="workdir-input" type="text" value="{escapeAttr(wd)}" size="24" spellcheck="false"
      placeholder="/absolute/path" title="Tools run with this as their working directory; the auto_workdir permission auto-approves file tools whose paths stay inside it.">
    <button type="button" id="workdir-save">Set</button>
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

proc historyPage*(ctx: Context) {.async, gcsafe.} =
  logInfo("routes", "GET /history")
  let s = getState()
  var rows = ""
  for (id, title, createdAt) in s.db.listConversations():
    rows.add(&"""<tr><td><a href="/chat/{id}">{escapeHtml(title)}</a></td><td>{createdAt}</td>
      <td><form class="inline" method="post" action="/history/delete" onsubmit="return confirm('Delete this conversation and its files? This cannot be undone.')"><input type="hidden" name="id" value="{id}"><button>Delete</button></form></td></tr>
""")
  let body = &"<h1>History</h1><table><tr><th>Title</th><th>Created</th><th></th></tr>{rows}</table>"
  resp htmlResponse(page("History", "/history", body))

proc historyDeletePost*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  try:
    let id = parseBiggestInt(ctx.getFormParams("id")).int64
    logInfo("routes", "POST /history/delete " & $id)
    s.db.deleteConversation(id)
    removeDir(convDir(s.dataDir, id))
  except ValueError:
    discard
  resp redirect("/history")

# ---------------- Models ----------------

proc modelsStatusJson*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  try:
    let models = await s.api.listModels()
    var arr = newJArray()
    for m in models:
      arr.add(%*{"id": m.id, "status": $m.status})
    resp jsonResponse(%*{"success": true, "models": arr})
  except CatchableError as e:
    resp jsonResponse(%*{"success": false, "error": e.msg})

proc modelsPage*(ctx: Context) {.async, gcsafe.} =
  logInfo("routes", "GET /models")
  let s = getState()
  var status = initTable[string, string]()
  if s.cfg.modelManagement:
    try:
      for m in await s.api.listModels():
        status[m.id] = $m.status
    except CatchableError as e:
      logError("api", "listModels failed: " & e.msg)
  var rows = ""
  try:
    for m in await availableModels(s):
      var actions = ""
      if s.cfg.modelManagement:
        actions = &"""<td class="model-status">{status.getOrDefault(m.name, "unknown")}</td><td>
          <button type="button" class="load-btn" data-model="{escapeAttr(m.name)}">Load</button>
          <button type="button" class="unload-btn" data-model="{escapeAttr(m.name)}">Unload</button>
          <span class="model-msg"></span></td>"""
      rows.add(&"""<tr id="model-row-{escapeAttr(m.name)}"><td>{escapeHtml(m.displayName)}</td><td>{escapeHtml(m.name)}</td>
        <td>{m.maxTokens}</td><td>{m.maxOutputTokens}</td><td>{escapeHtml(m.reasoningEffort)}</td><td>{m.tools}</td><td>{m.images}</td>{actions}</tr>""")
  except CatchableError as e:
    rows = &"<tr><td colspan=7>could not list models: {escapeHtml(e.msg)}</td></tr>"
  let mgmtHeaders = if s.cfg.modelManagement: "<th>Status</th><th>Actions</th>" else: ""
  let source = if s.cfg.models.len > 0: escapeHtml(s.cfg.modelsFile)
               else: "the backend's model list (no models file found at " & escapeHtml(s.cfg.modelsFile) & ")"
  let banner = await backendStatusBanner(s)
  let body = &"""{banner}
  <h1>Models</h1>
  <p>Backend: <code>{escapeHtml(s.cfg.apiUrl)}</code>. Models come from {source}.</p>
  <table id="models-table"><tr><th>Name</th><th>Id</th><th>Context</th><th>Max output</th><th>Reasoning</th><th>Tools</th><th>Images</th>{mgmtHeaders}</tr>{rows}</table>"""
  resp htmlResponse(page("Models", "/models", body))

proc modelOpPost(ctx: Context, load: bool) {.async, gcsafe.} =
  let s = getState()
  if not s.cfg.modelManagement:
    resp jsonResponse(%*{"success": false, "error": "model management is disabled (model_management=false)"}, Http403)
    return
  let model = parseJson(ctx.request.body){"model"}.getStr("")
  try:
    let res = if load: await s.api.loadModel(model) else: await s.api.unloadModel(model)
    resp jsonResponse(%*{"success": res.success, "error": res.error})
  except CatchableError as e:
    logError("routes", (if load: "load" else: "unload") & " model " & model & " failed: " & e.msg)
    resp jsonResponse(%*{"success": false, "error": e.msg})

proc modelsLoadPost*(ctx: Context) {.async, gcsafe.} =
  await modelOpPost(ctx, true)

proc modelsUnloadPost*(ctx: Context) {.async, gcsafe.} =
  await modelOpPost(ctx, false)

# ---------------- Tools (registry management: register/edit/delete tool
# manifests. Runtime approval/deny/kill of individual tool calls happens
# inline in the chat UI, never here.) ----------------

proc toolsPage*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  var rows = ""
  for t in s.toolRegistry.tools:
    rows.add(&"""<tr><td>{t.name}</td><td>{t.description}</td><td>{t.kind}</td><td><code>{t.entrypoint}</code></td><td>{t.permission}</td>
      <td><a href="/tools/edit/{t.name}">Edit</a></td>
      <td><form class="inline" method="post" action="/tools/delete"><input type="hidden" name="name" value="{t.name}"><button>Delete</button></form></td></tr>""")
  let body = &"""<h1>Tools</h1>
  <p>Register/edit the scripts and executables available to the agent. Approving, denying, or killing an individual tool call happens inline in the chat, not here.</p>
  <table><tr><th>Name</th><th>Description</th><th>Kind</th><th>Entrypoint</th><th>Permission</th><th></th><th></th></tr>{rows}</table>
  <h2>New tool</h2>
  <form method="post" action="/tools/new">
    <p>Name: <input name="name"></p>
    <p>Description: <input name="description" size="60"></p>
    <p>Kind: <select name="kind"><option value="shell">shell</option><option value="python">python</option><option value="nim-binary">nim-binary</option></select></p>
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

proc getOrCreateChatSession(s: AppState, convId: int64): Future[ChatSession] {.async.} =
  if s.chatSessions.hasKey(convId):
    return s.chatSessions[convId]
  let models = await availableModels(s)
  if models.len == 0:
    raise newException(CatchableError, "no models available")
  result = newChatSession(s.db, s.api, convId, none(int64), models[0], "chat")
  s.chatSessions[convId] = result

proc chatModelPost*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let convId = parseBiggestInt(ctx.getPathParams("id")).int64
  let modelId = parseJson(ctx.request.body){"model"}.getStr("")
  try:
    let entry = await findAvailableModel(s, modelId)
    s.chatSessions[convId] = newChatSession(s.db, s.api, convId, none(int64), entry, "chat")
    logInfo("routes", "conversation " & $convId & " switched to model " & modelId)
    resp jsonResponse(%*{"success": true, "ctx": entry.maxTokens})
  except CatchableError as e:
    logError("routes", "model switch failed: " & $e.name & ": " & e.msg)
    resp jsonResponse(%*{"success": false, "error": e.msg})

proc chatEffortPost*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let convId = parseBiggestInt(ctx.getPathParams("id")).int64
  let effort = parseJson(ctx.request.body){"effort"}.getStr("")
  if effort.len > 0 and effort notin effortLevels:
    resp jsonResponse(%*{"success": false, "error": "effort must be one of: " & effortLevels.join(", ")}, Http400)
    return
  s.db.setConversationEffort(convId, effort)
  if s.chatSessions.hasKey(convId):
    s.chatSessions[convId].effort = effort
  logInfo("routes", "conversation " & $convId & " effort set to '" & effort & "'")
  resp jsonResponse(%*{"success": true})

const titleGenThreshold = 3 ## generate a topic title once a conversation reaches this many messages

proc maybeGenerateTitle(s: AppState, convId: int64, sess: ChatSession,
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
    ## Heap-allocated state for a conversation's in-flight turn, shared by every
    ## browser connection to it (a reload must not start a second turn).
    ## Deliberately NOT captured as plain `var` locals closed over by
    ## a nested async proc: nested async closures over outer-proc locals
    ## have triggered segfaults on this toolchain, so the mutable state
    ## lives on its own ref object instead and every callback closes over
    ## that ref (safe) rather than the enclosing proc's stack frame.
    convId: int64
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

var
  turnStates: Table[int64, ChatTurnState]
  outQueues: Table[int64, TokenQueue] ## the queue of the browser connection currently attached to each conversation

proc turnFor(convId: int64): ChatTurnState {.gcsafe.} =
  {.cast(gcsafe).}:
    if not turnStates.hasKey(convId):
      turnStates[convId] = ChatTurnState(convId: convId, pendingIds: @[])
    result = turnStates[convId]

proc publish(convId: int64, ev: JsonNode) {.gcsafe.} =
  ## Dropped when no browser is attached; the DB already has everything.
  {.cast(gcsafe).}:
    if outQueues.hasKey(convId):
      outQueues[convId].push(ev)

# ---------------- Agent loop helpers ----------------

proc resolveApproval(s: AppState, id: int64) =
  ## Wakes whoever is awaiting approval of this tool call. The entry is removed
  ## first, so a late/duplicate approve for the same id can't act twice.
  if s.pendingApprovals.hasKey(id):
    let fut = s.pendingApprovals[id]
    s.pendingApprovals.del(id)
    s.pendingEvents.del(id)
    if not fut.finished:
      fut.complete()

proc makeWebHooks(s: AppState, st: ChatTurnState): AgentHooks =
  ## Everything the loop reports goes through the conversation's current
  ## connection queue so events stay in order with the streamed tokens (the
  ## queue is drained by `runSender`). A pending approval resolves when the
  ## approve/deny/cancel handler in `wsChat` calls `resolveApproval`.
  proc emitEvent(ev: JsonNode) {.gcsafe.} =
    publish(st.convId, ev)
  proc askFn(toolCallId: int64, toolName, argsJson: string): Future[void] {.gcsafe.} =
    let fut = newFuture[void]("pendingApproval")
    s.pendingApprovals[toolCallId] = fut
    st.pendingIds.add(toolCallId)
    let ev = %*{"type": "tool_call_pending", "id": toolCallId, "name": toolName, "args": argsJson,
                "conv": st.convId}
    s.pendingEvents[toolCallId] = ev
    publish(st.convId, ev)
    result = fut
  proc cancelledFn(): bool {.gcsafe.} =
    st.cancelled
  result = AgentHooks(emit: emitEvent, askApproval: askFn, isCancelled: cancelledFn)

proc executeApproved(s: AppState, convId, id: int64, toolName, argsJson: string) {.async, gcsafe.} =
  await s.toolExecutor.execute(convId, id, toolName, argsJson)
  resolveApproval(s, id)

proc handleUserMessage(s: AppState, convId: int64,
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
      let turn = await runAgentTurn(s.loop, convId, sess, makeWebHooks(s, st))
      let finalReply = turn.reply

      if finalReply.content.len == 0 and not st.cancelled:
        ## An empty, non-cancelled reply means something went wrong upstream
        ## (backend unreachable mid-stream, a malformed response, etc.) — don't
        ## silently store/show an empty assistant message, surface an error.
        let reason = if finalReply.error.len > 0: finalReply.error
                     else: "model returned an empty reply — check server logs"
        logError("ws", "conversation " & $convId & " got an EMPTY reply from the model: " & reason)
        publish(convId, %*{"type": "error", "content": reason})
      else:
        if finalReply.content.len == 0:
          logInfo("ws", "conversation " & $convId & " got an EMPTY reply from the model (cancelled=" & $st.cancelled & ")")
        else:
          logInfo("api", "sendTurn reply (" & $finalReply.content.len & " chars, " &
            $finalReply.reasoning.len & " reasoning char(s), cancelled=" & $st.cancelled & ")")
        publish(convId, %*{"type": "assistant_message", "content": finalReply.content,
                           "reasoning": finalReply.reasoning, "cancelled": st.cancelled})
      let newTitle = await maybeGenerateTitle(s, convId, sess, turn.history)
      if newTitle.isSome:
        publish(convId, %*{"type": "title_updated", "title": newTitle.get()})
    except CatchableError as e:
      logError("ws", "conversation " & $convId & " chat turn failed: " & $e.name & ": " & e.msg)
      publish(convId, %*{"type": "error", "content": e.msg})
  finally:
    st.generating = false

proc wsChat*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let convId = parseInt(ctx.getPathParams("id")).int64
  var ws = await newWebSocket(ctx)
  let st = turnFor(convId)
  ## This connection becomes the one the conversation's turn reports to; a turn
  ## started by an earlier connection (before a reload) keeps running and its
  ## events and approval prompts follow the browser here.
  let queue = newTokenQueue()
  {.cast(gcsafe).}:
    outQueues[convId] = queue
  let senderFut = runSender(ws, queue)
  if st.generating:
    queue.push(%*{"type": "turn_active"})
  for _, ev in s.pendingEvents:
    if ev{"conv"}.getBiggestInt() == convId:
      queue.push(ev)
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
          queue.push(%*{"type": "assistant_message", "content": "(a reply is already being generated — please wait)"})
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
            asyncCheck handleUserMessage(s, convId, st, content, fileIds)
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
          asyncCheck executeApproved(s, convId, id, toolName, argsJson)
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
  closeQueue(queue)
  {.cast(gcsafe).}:
    if outQueues.getOrDefault(convId) == queue:
      outQueues.del(convId)
  await senderFut

# ---------------- Chat settings, uploads, downloads ----------------

proc todosClearPost*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  try:
    let convId = parseBiggestInt(ctx.getPathParams("id")).int64
    s.db.clearTodos(convId)
    resp jsonResponse(%*{"success": true})
  except CatchableError as e:
    resp jsonResponse(%*{"success": false, "error": e.msg})

proc workdirGet*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  try:
    let convId = parseBiggestInt(ctx.getPathParams("id")).int64
    let wd = s.db.getConversationWorkingDir(convId)
    resp jsonResponse(%*{"success": true, "working_dir": wd})
  except CatchableError as e:
    resp jsonResponse(%*{"success": false, "error": e.msg})

proc workdirPost*(ctx: Context) {.async, gcsafe.} =
  ## Set the conversation's working directory. Stored verbatim (after trim);
  ## the gate normalises it with realpath at dispatch time, so there's no
  ## need to validate existence here (the user may point it at a dir they
  ## will create later, or a path relative to the host that a tool resolves).
  ## Empty string clears it.
  let s = getState()
  try:
    let convId = parseBiggestInt(ctx.getPathParams("id")).int64
    let wd = parseJson(ctx.request.body){"working_dir"}.getStr("").strip()
    s.db.setConversationWorkingDir(convId, wd)
    logInfo("routes", "conversation " & $convId & " working directory set to '" & wd & "'")
    resp jsonResponse(%*{"success": true, "working_dir": wd})
  except CatchableError as e:
    logError("routes", "set working dir failed: " & $e.name & ": " & e.msg)
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
