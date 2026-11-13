## OpenAI-compatible API (`/v1/models`, `/v1/chat/completions`), so editors such
## as Zed can use Cerisier as a model provider.
##
## Two ways to use a model, selected by the model id in the request:
##   * `<model>`          passthrough: the request (including any native `tools`)
##                        goes to the backend as-is and the reply is relayed.
##                        The client owns the tools; Cerisier runs none.
##   * `cerisier/<model>` agent mode: Cerisier's own loop and tools run
##                        server-side and only the resulting text is returned.
##                        Tools that need approval are denied (no UI to ask).

import std/[asyncdispatch, json, options, strformat, strutils, times]
import prologue
from httpx import closed
import ./routes
import ../config
import ../api/[client, session]
import ../agent/[conversation, hooks, loop]
import ../tools/executor
import ../log
import ../../common/types

const
  agentPrefix = "cerisier/"
  toolOpen = "<tool_call>"
  toolClose = "</tool_call>"

# ---------------- plumbing ----------------

proc errorBody(msg, kind: string): JsonNode =
  %*{"error": {"message": msg, "type": kind}}

proc fail(ctx: Context, code: HttpCode, msg, kind: string) =
  resp jsonResponse(errorBody(msg, kind), code)

proc sameSecret(a, b: string): bool =
  ## Constant-time comparison.
  if a.len != b.len:
    return false
  var diff = 0
  for i in 0 ..< a.len:
    diff = diff or (ord(a[i]) xor ord(b[i]))
  diff == 0

proc authorized(ctx: Context, s: AppState): bool =
  if s.cfg.serverToken.len == 0:
    return true
  if not ctx.request.hasHeader("Authorization"):
    return false
  let header = ctx.request.getHeader("Authorization")
  header.len > 0 and header[0].startsWith("Bearer ") and
    sameSecret(header[0][7 .. ^1].strip(), s.cfg.serverToken)

proc clientGone(ctx: Context): bool =
  ctx.request.nativeRequest.closed

proc sendChunk(ctx: Context, data: string) =
  ## One HTTP/1.1 chunk. The write is queued synchronously, so the returned
  ## future is already complete.
  discard ctx.send(&"{data.len:x}\r\n{data}\r\n")

proc startSse(ctx: Context) =
  discard ctx.send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" &
    "Cache-Control: no-cache\r\nTransfer-Encoding: chunked\r\n\r\n")

proc sendEvent(ctx: Context, payload: string) =
  sendChunk(ctx, "data: " & payload & "\n\n")

proc endSse(ctx: Context) =
  sendEvent(ctx, "[DONE]")
  discard ctx.send("0\r\n\r\n")
  ctx.handled = true

proc chunkJson(id, model: string, delta: JsonNode, finish: JsonNode = newJNull()): JsonNode =
  %*{"id": id, "object": "chat.completion.chunk", "created": toUnix(getTime()), "model": model,
     "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}

proc messageText(content: JsonNode): string =
  ## Message content is a string or an array of typed parts; keep the text.
  if content == nil:
    return ""
  if content.kind == JString:
    return content.getStr()
  if content.kind == JArray:
    var parts: seq[string] = @[]
    for p in content:
      if p{"type"}.getStr() == "text":
        parts.add(p{"text"}.getStr())
    return parts.join("\n")
  ""

# ---------------- hiding <tool_call> tags while streaming ----------------

type
  TagFilter = ref object
    buf: string
    inTag: bool

proc partialPrefixLen(s, tag: string): int =
  ## Length of the longest suffix of `s` that is a proper prefix of `tag`.
  for n in countdown(min(s.len, tag.len - 1), 1):
    if s[s.len - n .. ^1] == tag[0 ..< n]:
      return n
  0

proc feed(f: TagFilter, text: string): string =
  ## Returns the part of `text` that is not inside a tool-call tag, holding
  ## back a trailing fragment that might still turn out to be a tag opening.
  f.buf.add(text)
  while true:
    if f.inTag:
      let i = f.buf.find(toolClose)
      if i < 0:
        let keep = partialPrefixLen(f.buf, toolClose)
        f.buf = f.buf[f.buf.len - keep .. ^1]
        return
      f.buf = f.buf[i + toolClose.len .. ^1]
      f.inTag = false
    else:
      let i = f.buf.find(toolOpen)
      if i >= 0:
        result.add(f.buf[0 ..< i])
        f.buf = f.buf[i + toolOpen.len .. ^1]
        f.inTag = true
      else:
        let keep = partialPrefixLen(f.buf, toolOpen)
        result.add(f.buf[0 ..< f.buf.len - keep])
        f.buf = f.buf[f.buf.len - keep .. ^1]
        return

proc finish(f: TagFilter): string =
  if not f.inTag:
    result = f.buf
  f.buf = ""

# ---------------- GET /v1/models ----------------

proc v1Models*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  if not authorized(ctx, s):
    fail(ctx, Http401, "invalid or missing bearer token", "invalid_request_error")
    return
  try:
    let models = await availableModels(s)
    var data = newJArray()
    for m in models:
      data.add(%*{"id": m.name, "object": "model", "owned_by": "cerisier"})
    for m in models:
      data.add(%*{"id": agentPrefix & m.name, "object": "model", "owned_by": "cerisier"})
    resp jsonResponse(%*{"object": "list", "data": data})
  except CatchableError as e:
    fail(ctx, Http502, e.msg, "api_error")

# ---------------- passthrough ----------------

proc passthrough(ctx: Context, s: AppState, body: JsonNode) {.async, gcsafe.} =
  let streaming = body{"stream"}.getBool(false)
  if not streaming:
    try:
      resp jsonResponse(await s.api.postJson("/chat/completions", body))
    except CatchableError as e:
      fail(ctx, Http502, e.msg, "api_error")
    return

  var started = false
  let onData = proc(payload: string): Future[void] {.async, gcsafe.} =
    if not started:
      started = true
      startSse(ctx)
    sendEvent(ctx, payload)
  let gone = proc(): bool {.gcsafe.} = clientGone(ctx)
  try:
    await s.api.streamSse("/chat/completions", body, onData, gone)
  except CatchableError as e:
    if not started:
      fail(ctx, Http502, e.msg, "api_error")
      return
    sendEvent(ctx, $errorBody(e.msg, "api_error"))
  if not started:
    startSse(ctx)
  endSse(ctx)

# ---------------- agent mode ----------------

proc seedConversation(s: AppState, messages: JsonNode): int64 =
  ## One new conversation per request, filled from the client's messages. The
  ## client's system prompt describes the client's own tools, so it is dropped.
  var title = "API request"
  for m in messages:
    if m{"role"}.getStr() == "user":
      let t = messageText(m{"content"}).strip().replace('\n', ' ')
      if t.len > 0:
        title = "API: " & (if t.len > 50: t[0 ..< 50] else: t)
      break
  result = s.orchestrator.startConversation(title)
  for m in messages:
    let role = m{"role"}.getStr()
    let text = messageText(m{"content"})
    if role in ["user", "assistant"] and text.strip().len > 0:
      discard s.orchestrator.appendMessage(result, none(int64), role, text)

proc agentMode(ctx: Context, s: AppState, body: JsonNode, entry: ModelEntry) {.async, gcsafe.} =
  let messages = body{"messages"}
  if messages == nil or messages.kind != JArray or messages.len == 0:
    fail(ctx, Http400, "messages must be a non-empty array", "invalid_request_error")
    return
  let streaming = body{"stream"}.getBool(false)
  let wantUsage = body{"stream_options"}{"include_usage"}.getBool(false)
  let modelId = agentPrefix & entry.name
  let completionId = "chatcmpl-" & $toUnix(getTime()) & $(getTime().nanosecond div 1000)

  let convId = seedConversation(s, messages)
  let sess = newChatSession(s.db, s.api, convId, none(int64), entry, "api")
  logInfo("api", "agent request conversation=" & $convId & " model=" & entry.name & " stream=" & $streaming)

  let filter = TagFilter(buf: "", inTag: false)
  if streaming:
    startSse(ctx)
    sendEvent(ctx, $chunkJson(completionId, modelId, %*{"role": "assistant"}))

  let emitDelta = proc(delta: JsonNode) {.gcsafe.} =
    if streaming:
      sendEvent(ctx, $chunkJson(completionId, modelId, delta))
  proc onEvent(ev: JsonNode) {.gcsafe.} =
    case ev{"type"}.getStr()
    of "assistant_token":
      let visible = filter.feed(ev{"content"}.getStr())
      if visible.len > 0:
        emitDelta(%*{"content": visible})
    of "reasoning_token":
      emitDelta(%*{"reasoning_content": ev{"content"}.getStr()})
    of "tool_call_result":
      emitDelta(%*{"content": "\n\n*[tool " & ev{"name"}.getStr() & ": " & ev{"status"}.getStr() & "]*\n\n"})
    else:
      discard
  proc denyApproval(toolCallId: int64, toolName, argsJson: string): Future[void] {.gcsafe.} =
    s.toolExecutor.deny(toolCallId)
    result = newFuture[void]("apiDeny")
    result.complete()
  proc cancelled(): bool {.gcsafe.} =
    clientGone(ctx)
  let hooks = AgentHooks(emit: onEvent, askApproval: denyApproval, isCancelled: cancelled)

  var turn: TurnResult
  var failure = ""
  try:
    turn = await runAgentTurn(s.loop, convId, sess, hooks)
  except CatchableError as e:
    failure = e.msg
    logError("api", "agent request failed: " & $e.name & ": " & e.msg)
  if failure.len == 0 and turn.reply.content.len == 0 and turn.reply.error.len > 0:
    failure = turn.reply.error

  if streaming:
    let tail = filter.finish()
    if tail.len > 0:
      emitDelta(%*{"content": tail})
    if failure.len > 0:
      sendEvent(ctx, $errorBody(failure, "api_error"))
    sendEvent(ctx, $chunkJson(completionId, modelId, newJObject(), %"stop"))
    if wantUsage:
      var usage = chunkJson(completionId, modelId, newJObject())
      usage["choices"] = newJArray()
      usage["usage"] = %*{"prompt_tokens": sess.promptTokens, "completion_tokens": sess.completionTokens,
                          "total_tokens": sess.promptTokens + sess.completionTokens}
      sendEvent(ctx, $usage)
    endSse(ctx)
    return

  if failure.len > 0:
    fail(ctx, Http502, failure, "api_error")
    return
  resp jsonResponse(%*{
    "id": completionId, "object": "chat.completion", "created": toUnix(getTime()), "model": modelId,
    "choices": [{"index": 0, "message": {"role": "assistant", "content": turn.reply.content},
                 "finish_reason": "stop"}],
    "usage": {"prompt_tokens": sess.promptTokens, "completion_tokens": sess.completionTokens,
              "total_tokens": sess.promptTokens + sess.completionTokens}})

# ---------------- POST /v1/chat/completions ----------------

proc v1ChatCompletions*(ctx: Context) {.async, gcsafe.} =
  let s = getState()
  if not authorized(ctx, s):
    fail(ctx, Http401, "invalid or missing bearer token", "invalid_request_error")
    return
  ## Read the body first: the server drops it once it starts writing a reply.
  var body: JsonNode
  try:
    body = parseJson(ctx.request.body)
  except CatchableError:
    fail(ctx, Http400, "request body is not valid JSON", "invalid_request_error")
    return
  if body.kind != JObject:
    fail(ctx, Http400, "request body must be a JSON object", "invalid_request_error")
    return
  let model = body{"model"}.getStr("")
  try:
    if model.startsWith(agentPrefix):
      let entry = await findAvailableModel(s, model[agentPrefix.len .. ^1])
      await agentMode(ctx, s, body, entry)
    else:
      await passthrough(ctx, s, body)
  except CatchableError as e:
    logError("api", "chat completion failed: " & $e.name & ": " & e.msg)
    fail(ctx, Http400, e.msg, "invalid_request_error")
