## A bounded conversation against the backend's /v1/chat/completions for one
## model. Tracks token usage and decides when the context is close to full,
## triggering a pluggable "context strategy" (v1: summarize-and-continue).

import std/[json, options, asyncdispatch]
import ./client
import ../config
import ../db/database

type
  ContextStrategy* = enum
    csSummarizeAndContinue

  SessionStatus* = enum
    ssOpen = "open"
    ssClosed = "closed"
    ssSummarizing = "summarizing"

  ChatSession* = ref object
    id*: int64
    db: Database
    api: ApiClient
    entry*: ModelEntry
    model*: string
    ctxSize*: int
    effort*: string ## per-chat reasoning effort; "" falls back to the model entry's
    promptTokens*: int
    completionTokens*: int
    status*: SessionStatus
    strategy*: ContextStrategy

proc newChatSession*(db: Database, api: ApiClient, conversationId: int64,
                       parentMessageId: Option[int64], entry: ModelEntry, purpose: string,
                       strategy = csSummarizeAndContinue): ChatSession =
  let id = db.createLlamaSession(conversationId, parentMessageId, entry.name, purpose, entry.maxTokens)
  ChatSession(id: id, db: db, api: api, entry: entry, model: entry.name, ctxSize: entry.maxTokens,
               effort: db.getConversationEffort(conversationId), promptTokens: 0, completionTokens: 0, status: ssOpen, strategy: strategy)

const contextSafetyMargin = 0.9 ## trigger strategy at 90% of ctxSize

proc isNearContextLimit*(session: ChatSession): bool =
  if session.ctxSize <= 0:
    return false
  let total = session.promptTokens + session.completionTokens
  total.float >= session.ctxSize.float * contextSafetyMargin

proc recordUsage*(session: ChatSession, promptTokens, completionTokens: int) =
  session.promptTokens = promptTokens
  session.completionTokens = completionTokens
  session.db.updateSessionTokens(session.id, promptTokens, completionTokens)

type
  ChatMsg* = object
    ## One chat-completions message. `images` holds `data:` URIs; when present
    ## the message is sent as OpenAI-style content parts (text + image_url).
    role*: string
    content*: string
    images*: seq[string]
    reasoning*: string ## sent as `reasoning_content` on assistant messages

proc chatMsg*(role, content: string, images: seq[string] = @[]): ChatMsg =
  ChatMsg(role: role, content: content, images: images)

proc toChatMsgs*(messages: seq[(string, string)]): seq[ChatMsg] =
  result = @[]
  for (role, content) in messages:
    result.add(chatMsg(role, content))

proc buildChatRequest(entry: ModelEntry, effort: string, messages: seq[ChatMsg], stream: bool): JsonNode =
  var msgs = newJArray()
  for m in messages:
    var msg: JsonNode
    if m.images.len == 0:
      msg = %*{"role": m.role, "content": m.content}
    else:
      var parts = newJArray()
      parts.add(%*{"type": "text", "text": m.content})
      for img in m.images:
        parts.add(%*{"type": "image_url", "image_url": {"url": img}})
      msg = %*{"role": m.role, "content": parts}
    if m.reasoning.len > 0:
      msg["reasoning_content"] = %m.reasoning
    msgs.add(msg)
  result = %*{"model": entry.name, "messages": msgs, "stream": stream}
  if stream:
    result["stream_options"] = %*{"include_usage": true}
  if entry.maxOutputTokens > 0:
    result["max_tokens"] = %entry.maxOutputTokens
  let level = if effort.len > 0: effort else: entry.reasoningEffort
  if level.len > 0:
    result["reasoning_effort"] = %level

proc sendTurn*(session: ChatSession, messages: seq[ChatMsg]): Future[string] {.async.} =
  ## Sends a full-history chat turn to the backend and returns the assistant
  ## text. Records token usage from the `usage` field. Raises on transport
  ## error — callers should catch when the backend is unreachable.
  let body = buildChatRequest(session.entry, session.effort, messages, stream = false)
  let resp = await session.api.postJson("/chat/completions", body)
  let usage = resp{"usage"}
  if usage != nil:
    session.recordUsage(usage{"prompt_tokens"}.getInt(session.promptTokens),
                          usage{"completion_tokens"}.getInt(session.completionTokens))
  let choices = resp{"choices"}
  if choices != nil and choices.kind == JArray and choices.len > 0:
    result = choices[0]{"message"}{"content"}.getStr("")
    discard session.db.addTurn(session.id, "assistant", result)
  else:
    result = ""

proc sendTurn*(session: ChatSession, messages: seq[(string, string)]): Future[string] {.async.} =
  ## Convenience overload for plain (role, content) histories.
  result = await session.sendTurn(toChatMsgs(messages))

type
  StreamingReply* = object
    content*: string
    reasoning*: string
    error*: string ## set when the backend reported/caused a failure; content may still be partial

proc sendTurnStreaming*(session: ChatSession, messages: seq[ChatMsg],
                         onToken: proc(tok: string): Future[void] {.gcsafe.},
                         onReasoning: proc(tok: string): Future[void] {.gcsafe.},
                         isCancelled: proc(): bool {.gcsafe.}): Future[StreamingReply] {.async, gcsafe.} =
  ## Like `sendTurn`, but streams the assistant reply token-by-token via
  ## `onToken` (awaited for each chunk) as it's generated, and can be
  ## aborted early by `isCancelled`. Reasoning/thinking tokens (if the model
  ## emits them) are streamed separately via `onReasoning`. Whatever text
  ## was accumulated so far (full or partial, if cancelled) is recorded as
  ## the turn and returned. On transport failure `result.error` is set
  ## instead of raising, so callers can report it to the user.
  let body = buildChatRequest(session.entry, session.effort, messages, stream = true)
  var resp: JsonNode
  try:
    resp = await session.api.postJsonStream("/chat/completions", body, onToken, onReasoning, isCancelled)
  except CatchableError as e:
    result.error = e.msg
    return
  let usage = resp{"usage"}
  if usage != nil:
    session.recordUsage(usage{"prompt_tokens"}.getInt(session.promptTokens),
                          usage{"completion_tokens"}.getInt(session.completionTokens))
  result.content = resp{"content"}.getStr("")
  result.reasoning = resp{"reasoning"}.getStr("")
  result.error = resp{"error"}.getStr("")
  if result.content.len > 0:
    discard session.db.addTurn(session.id, "assistant", result.content)


proc summarizePrompt(): string =
  "Summarize the conversation so far concisely, preserving all facts and " &
  "decisions needed to continue the task. This summary will seed a fresh " &
  "context window."

proc summarizeAndContinue*(session: ChatSession, history: seq[(string, string)]): Future[string] {.async.} =
  ## Asks the model to summarize `history`, closes this session, and returns
  ## the summary text so the caller can open a fresh ChatSession seeded
  ## with it.
  var req = history
  req.add(("user", summarizePrompt()))
  let summary = await session.sendTurn(req)
  session.db.closeSession(session.id, "closed")
  session.status = ssClosed
  summary
