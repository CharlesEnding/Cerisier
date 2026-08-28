## HTTP + WebSocket routes for the Cerisier web UI.
## Every page is a normal server-rendered full page load, except the chat
## page's WebSocket channel which live-updates in place.

import std/[asyncdispatch, json, strformat, options, strutils, tables, sequtils]
import prologue
import prologue/websocket
import ./layout
import ../db/database
import ../skills/skills
import ../formats/formats
import ../llama/router_client
import ../llama/session
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

var state*: AppState

proc getState(): AppState {.gcsafe.} =
  {.cast(gcsafe).}:
    result = state

proc staticAsset*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let filename = ctx.getPathParams("file")
  await staticFileResponse(ctx, filename, s.staticDir)

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
    let models = s.router.listModels()
    if s.chatSessions.hasKey(currentId):
      currentModel = s.chatSessions[currentId].model
    for m in models:
      let selected = if m.id == currentModel: " selected" else: ""
      modelOptions.add(&"<option value=\"{m.id}\"{selected}>{m.id} ({m.status})</option>")
  except CatchableError as e:
    logInfo("router", "listModels failed: " & e.msg)
  let body = &"""
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

proc historyPage*(ctx: Context) {.async, gcsafe.} =
  logInfo("routes", "GET /history")
  let s = getState()
  var rows = ""
  for (id, title, createdAt) in s.db.listConversations():
    rows.add(&"<tr><td><a href=\"/chat/{id}\">{title}</a></td><td>{createdAt}</td></tr>\n")
  let body = &"<h1>History</h1><table><tr><th>Title</th><th>Created</th></tr>{rows}</table>"
  resp htmlResponse(page("History", "/history", body))

# ---------------- Models ----------------

proc modelsPage*(ctx: Context) {.async, gcsafe.} =
  logInfo("routes", "GET /models")
  let s = getState()
  var rows = ""
  try:
    let models = s.router.listModels()
    logInfo("router", "listModels -> " & $models.len & " model(s)")
    for m in models:
      rows.add(&"""<tr><td>{m.id}</td><td>{m.status}</td><td>{m.supportsVision}</td>
        <td>
          <form class="inline" method="post" action="/models/load"><input type="hidden" name="model" value="{m.id}"><button>Load</button></form>
          <form class="inline" method="post" action="/models/unload"><input type="hidden" name="model" value="{m.id}"><button>Unload</button></form>
        </td></tr>""")
  except CatchableError as e:
    logInfo("router", "listModels failed: " & e.msg)
    rows = &"<tr><td colspan=4>router unreachable: {e.msg}</td></tr>"
  let body = &"""<h1>Models</h1>
  <table><tr><th>Model</th><th>Status</th><th>Vision</th><th>Actions</th></tr>{rows}</table>"""
  resp htmlResponse(page("Models", "/models", body))


proc modelsLoadPost*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let model = ctx.getFormParams("model")
  try:
    discard s.router.loadModel(model)
  except CatchableError: discard
  resp redirect("/models")

proc modelsUnloadPost*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let model = ctx.getFormParams("model")
  try:
    discard s.router.unloadModel(model)
  except CatchableError: discard
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

proc pickChatModel(s: AppState): string =
  let models = s.router.listModels()
  for m in models:
    if m.status == msvLoaded:
      return m.id
  if models.len > 0:
    discard s.router.loadModel(models[0].id)
    return models[0].id
  raise newException(CatchableError, "no models available")

proc getOrCreateChatSession(s: AppState, convId: int64): LlamaSession =
  if s.chatSessions.hasKey(convId):
    return s.chatSessions[convId]
  let model = pickChatModel(s)
  result = newLlamaSession(s.db, s.router, convId, none(int64), model, "chat", 8192)
  s.chatSessions[convId] = result

proc switchChatModel(s: AppState, convId: int64, modelId: string): bool =
  ## Unloads the conversation's current model (if any and different) before
  ## loading the requested one, since the router/GPU may not have room to
  ## keep both loaded at once. Returns false (without touching the cached
  ## session) if the load fails, so a failed switch doesn't silently strand
  ## the conversation on a half-switched state.
  if s.chatSessions.hasKey(convId):
    let oldModel = s.chatSessions[convId].model
    if oldModel != modelId:
      let unloaded = s.router.unloadModel(oldModel)
      logInfo("router", "unload " & oldModel & " -> success=" & $unloaded)
  let loaded = s.router.loadModel(modelId)
  logInfo("router", "load " & modelId & " -> success=" & $loaded)
  if not loaded:
    return false
  s.chatSessions[convId] = newLlamaSession(s.db, s.router, convId, none(int64), modelId, "chat", 8192)
  true

proc chatModelPost*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let convId = parseBiggestInt(ctx.getPathParams("id")).int64
  let payload = parseJson(ctx.request.body)
  let modelId = payload{"model"}.getStr("")
  try:
    if switchChatModel(s, convId, modelId):
      logInfo("routes", "conversation " & $convId & " switched to model " & modelId)
      resp jsonResponse(%*{"success": true})
    else:
      logInfo("routes", "conversation " & $convId & " failed to switch to model " & modelId & " (router declined load)")
      resp jsonResponse(%*{"success": false, "error": "router declined to load model " & modelId})
  except CatchableError as e:
    logInfo("routes", "model switch failed: " & $e.name & ": " & e.msg)
    resp jsonResponse(%*{"success": false, "error": e.msg})

const titleGenThreshold = 3 ## generate a topic title once a conversation reaches this many messages

proc maybeGenerateTitle(s: AppState, convId: int64, sess: LlamaSession,
                         history: seq[(string, string)]): Option[string] =
  ## After a few messages, ask the model for a short topic title and store
  ## it, replacing the default "New conversation" placeholder.
  if history.len < titleGenThreshold:
    return none(string)
  if s.db.getConversationTitle(convId) != "New conversation":
    return none(string)
  try:
    let prompt = @[("user", "In 3-6 words, give a short topic title for this " &
                            "conversation. Reply with only the title, no punctuation.")]
    let title = sess.sendTurn(history & prompt).strip(chars = {' ', '\n', '\t', '"', '.'})
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

proc handleUserMessage(s: AppState, convId: int64, ws: WebSocket,
                        st: ChatTurnState, content: string) {.async, gcsafe.} =
  st.generating = true
  st.cancelled = false
  try:
    discard s.orchestrator.appendMessage(convId, none(int64), "user", content)
    logInfo("ws", "conversation " & $convId & " user message (" & $content.len & " chars)")
    try:
      let sess = getOrCreateChatSession(s, convId)
      var history: seq[(string, string)] = @[]
      for (mid, parentId, role, msgContent, createdAt) in s.db.messagesForConversation(convId):
        if role == "reasoning":
          continue ## not a valid chat-completions role; kept in the DB only for display
        history.add((role, msgContent))
      logInfo("router", "sendTurn model=" & sess.model & " messages=" & $history.len)
      let onToken = proc(tok: string): Future[void] {.gcsafe.} =
        ws.send($(%*{"type": "assistant_token", "content": tok}))
      let onReasoning = proc(tok: string): Future[void] {.gcsafe.} =
        ws.send($(%*{"type": "reasoning_token", "content": tok}))
      let isCancelled = proc(): bool {.gcsafe.} =
        st.cancelled
      let reply = await sess.sendTurnStreaming(history, onToken, onReasoning, isCancelled)
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
      let newTitle = maybeGenerateTitle(s, convId, sess, history)
      if newTitle.isSome:
        await ws.send($(%*{"type": "title_updated", "title": newTitle.get()}))
    except CatchableError as e:
      logInfo("ws", "conversation " & $convId & " chat turn failed: " & $e.name & ": " & e.msg)
      await ws.send($(%*{"type": "assistant_message", "content": "(error: " & e.msg & ")"}))
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
