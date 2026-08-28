## HTTP + WebSocket routes for the Cerisier web UI.
## Every page is a normal server-rendered full page load, except the chat
## page's WebSocket channel which live-updates in place.

import std/[asyncdispatch, json, strformat, options, strutils]
import prologue
import prologue/websocket
import ./layout
import ../db/database
import ../skills/skills
import ../formats/formats
import ../llama/router_client
import ../agent/conversation
import ../../common/types

type
  AppState* = ref object
    db*: Database
    router*: RouterClient
    orchestrator*: ConversationOrchestrator
    staticDir*: string

var state*: AppState

proc getState(): AppState {.gcsafe.} =
  {.cast(gcsafe).}:
    result = state

proc staticAsset*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  let filename = ctx.getPathParams("file")
  await staticFileResponse(ctx, filename, s.staticDir)

# ---------------- Chat (the one live-updating page) ----------------

proc chatPage*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  var convId = s.db.listConversations()
  var currentId: int64
  if convId.len == 0:
    currentId = s.orchestrator.startConversation("New conversation")
  else:
    currentId = convId[0][0]
  var log = ""
  for (id, parentId, role, content, createdAt) in s.db.messagesForConversation(currentId):
    log.add(&"<div class=\"msg {role}\">{content}</div>\n")
  let body = &"""
  <h1>Conversation #{currentId}</h1>
  <div id="chat-log">{log}</div>
  <form id="chat-form">
    <input id="chat-input" type="text" placeholder="Message..." style="width:70%">
    <button type="submit">Send</button>
  </form>
  <script>connectChat({currentId});</script>
  """
  resp htmlResponse(page("Chat", "/", body))

proc historyPage*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  var rows = ""
  for (id, title, createdAt) in s.db.listConversations():
    rows.add(&"<tr><td><a href=\"/chat/{id}\">{title}</a></td><td>{createdAt}</td></tr>\n")
  let body = &"<h1>History</h1><table><tr><th>Title</th><th>Created</th></tr>{rows}</table>"
  resp htmlResponse(page("History", "/history", body))

# ---------------- Models ----------------

proc modelsPage*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  var rows = ""
  try:
    for m in s.router.listModels():
      rows.add(&"""<tr><td>{m.id}</td><td>{m.status}</td><td>{m.supportsVision}</td>
        <td>
          <form class="inline" method="post" action="/models/load"><input type="hidden" name="model" value="{m.id}"><button>Load</button></form>
          <form class="inline" method="post" action="/models/unload"><input type="hidden" name="model" value="{m.id}"><button>Unload</button></form>
        </td></tr>""")
  except CatchableError as e:
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
        await ws.send($(%*{"type": "assistant_message",
          "content": "(no router connected on this dev machine — message stored)"}))
    except WebSocketError:
      break
