## A bounded conversation against the router's /v1/chat/completions for one
## model. Tracks token usage and decides when the context is close to full,
## triggering a pluggable "context strategy" (v1: summarize-and-continue).
##
## No live router is required to compile or reason about this module: the
## actual HTTP call is isolated in `sendTurn`, which callers may choose not
## to invoke (e.g. when there's no router running, as on this dev machine).

import std/[json, options, asyncdispatch]
import ./router_client
import ../db/database

type
  ContextStrategy* = enum
    csSummarizeAndContinue

  SessionStatus* = enum
    ssOpen = "open"
    ssClosed = "closed"
    ssSummarizing = "summarizing"

  LlamaSession* = ref object
    id*: int64
    db: Database
    router: RouterClient
    model*: string
    ctxSize*: int
    promptTokens*: int
    completionTokens*: int
    status*: SessionStatus
    strategy*: ContextStrategy

proc newLlamaSession*(db: Database, router: RouterClient, conversationId: int64,
                       parentMessageId: Option[int64], model: string, purpose: string,
                       ctxSize: int, strategy = csSummarizeAndContinue): LlamaSession =
  let id = db.createLlamaSession(conversationId, parentMessageId, model, purpose, ctxSize)
  LlamaSession(id: id, db: db, router: router, model: model, ctxSize: ctxSize,
               promptTokens: 0, completionTokens: 0, status: ssOpen, strategy: strategy)

const contextSafetyMargin = 0.9 ## trigger strategy at 90% of ctxSize

proc isNearContextLimit*(session: LlamaSession): bool =
  if session.ctxSize <= 0:
    return false
  let total = session.promptTokens + session.completionTokens
  total.float >= session.ctxSize.float * contextSafetyMargin

proc recordUsage*(session: LlamaSession, promptTokens, completionTokens: int) =
  session.promptTokens = promptTokens
  session.completionTokens = completionTokens
  session.db.updateSessionTokens(session.id, promptTokens, completionTokens)

proc buildChatRequest(model: string, messages: seq[(string, string)], stream: bool): JsonNode =
  var msgs = newJArray()
  for (role, content) in messages:
    msgs.add(%*{"role": role, "content": content})
  %*{"model": model, "messages": msgs, "stream": stream}

proc sendTurn*(session: LlamaSession, messages: seq[(string, string)]): Future[string] {.async.} =
  ## Sends a full-history chat turn to the router and returns the assistant
  ## text. Records token usage from the `usage` field. Raises on transport
  ## error — callers should catch when no router is reachable.
  let body = buildChatRequest(session.model, messages, stream = false)
  let resp = await session.router.postJson("/v1/chat/completions", body)
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

type
  StreamingReply* = object
    content*: string
    reasoning*: string
    error*: string ## set when the router reported/caused a failure; content may still be partial

proc sendTurnStreaming*(session: LlamaSession, messages: seq[(string, string)],
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
  let body = buildChatRequest(session.model, messages, stream = true)
  var resp: JsonNode
  try:
    resp = await session.router.postJsonStream("/v1/chat/completions", body, onToken, onReasoning, isCancelled)
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

proc summarizeAndContinue*(session: LlamaSession, history: seq[(string, string)]): Future[string] {.async.} =
  ## Asks the model to summarize `history`, closes this session, and returns
  ## the summary text so the caller can open a fresh LlamaSession seeded
  ## with it.
  var req = history
  req.add(("user", summarizePrompt()))
  let summary = await session.sendTurn(req)
  session.db.closeSession(session.id, "closed")
  session.status = ssClosed
  summary
