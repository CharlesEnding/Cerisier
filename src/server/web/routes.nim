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
import ../log
import ../../common/types

type
  AppState* = ref object
    db*: Database
    router*: RouterClient
    orchestrator*: ConversationOrchestrator
    staticDir*: string
    chatSessions*: Table[int64, LlamaSession] ## one live session per conversation, lazily created

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
    log.add(&"<div class=\"msg {role}\">{content}</div>\n")
  let body = &"""
  <h1>Conversation #{currentId}</h1>
  <div id="chat-log">{log}</div>
  <form id="chat-form">
    <input id="chat-input" type="text" placeholder="Message..." autocomplete="off">
    <button type="submit">Send</button>
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

# ---------------- Tools (+ approval queue) ----------------

proc toolsPage*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  var rows = ""
  for (id, messageId, toolName, location, argsJson) in s.db.pendingToolCalls():
    rows.add(&"""<tr class="pending"><td>{id}</td><td>{toolName}</td><td>{location}</td><td><code>{argsJson}</code></td>
      <td>
        <form class="inline" method="post" action="/tools/approve"><input type="hidden" name="id" value="{id}"><button>Approve</button></form>
        <form class="inline" method="post" action="/tools/deny"><input type="hidden" name="id" value="{id}"><button>Deny</button></form>
      </td></tr>""")
  let body = &"""<h1>Tools — Pending Approval</h1>
  <p>Every tool call is shown here with its exact parameters before it can run.</p>
  <table><tr><th>#</th><th>Tool</th><th>Location</th><th>Args</th><th>Action</th></tr>{rows}</table>"""
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

proc wsChat*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let convId = parseInt(ctx.getPathParams("id"))
  var ws = await newWebSocket(ctx)
  while ws.readyState == Open:
    try:
      let packet = await ws.receiveStrPacket()
      let node = parseJson(packet)
      if node{"type"}.getStr("") == "user_message":
        let content = node{"content"}.getStr("")
        discard s.orchestrator.appendMessage(convId.int64, none(int64), "user", content)
        logInfo("ws", "conversation " & $convId & " user message (" & $content.len & " chars)")
        try:
          let sess = getOrCreateChatSession(s, convId.int64)
          var history: seq[(string, string)] = @[]
          for (mid, parentId, role, msgContent, createdAt) in s.db.messagesForConversation(convId.int64):
            history.add((role, msgContent))
          logInfo("router", "sendTurn model=" & sess.model & " messages=" & $history.len)
          let reply = sess.sendTurn(history)
          logInfo("router", "sendTurn reply (" & $reply.len & " chars): " & reply[0 ..< min(120, reply.len)])
          discard s.orchestrator.appendMessage(convId.int64, none(int64), "assistant", reply)
          await ws.send($(%*{"type": "assistant_message", "content": reply}))
        except CatchableError as e:
          logInfo("ws", "chat turn failed: " & e.msg)
          await ws.send($(%*{"type": "assistant_message", "content": "(error: " & e.msg & ")"}))
    except WebSocketError:
      break
    except CatchableError as e:
      logInfo("ws", "unexpected error: " & e.msg)
      break
