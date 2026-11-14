## The agent loop: ask the model, run the tools it calls, feed the results
## back, repeat until it answers without a tool call. Transport-agnostic: the
## web UI and the HTTP API both drive it through `AgentHooks`.

import std/[json, options, asyncdispatch]
from std/times import parse, utc, local, format
import ../db/database
import ../api/client
import ../api/session
import ../files/files
import ../tools/registry
import ../tools/executor
import ../tools/builtin
import ../tools/toolcalls
import ../log
import ../../common/types
import ./hooks
import ./prompt
import ./subagent

type
  LoopEnv* = ref object
    db*: Database
    api*: ApiClient
    registry*: ToolRegistry
    executor*: ToolExecutor
    dataDir*: string
    promptFile*: string

  TurnResult* = object
    reply*: StreamingReply
    history*: seq[ChatMsg]   ## the last history sent to the model

proc stamp(createdAt: string): string =
  ## The DB stores UTC; the model sees the host's local time.
  try:
    "[" & parse(createdAt, "yyyy-MM-dd HH:mm:ss", utc()).local.format("yyyy-MM-dd HH:mm") & "] "
  except CatchableError:
    ""

proc buildHistory*(env: LoopEnv, convId: int64, visionOk: bool): seq[ChatMsg] =
  ## The main model's context: system prompt (tools, formatting, todo + file
  ## snapshot) plus the *top-level* messages. Messages that belong to a
  ## sub-agent (they have a parent) are deliberately left out — keeping them
  ## out of this context is the whole point of sub-agents.
  result = @[]
  let sys = buildSystemPrompt(env.db, env.registry, convId, env.promptFile)
  if sys.len > 0:
    result.add(chatMsg("system", sys))
  for (mid, parentId, role, msgContent, createdAt) in env.db.messagesForConversation(convId):
    if parentId.len > 0:
      continue
    if role == "reasoning":
      continue ## not a valid chat-completions role; kept in the DB only for display
    if role == "user":
      let text = stamp(createdAt) & msgContent
      let att = describeAttachments(env.db, env.dataDir, mid, visionOk)
      if att.note.len > 0 or att.images.len > 0:
        result.add(chatMsg(role, text & att.note, att.images))
      else:
        result.add(chatMsg(role, text))
      continue
    result.add(chatMsg(role, if role == "assistant": stamp(createdAt) & msgContent else: msgContent))

proc runBuiltinCall(env: LoopEnv, convId, assistantMsgId: int64, hooks: AgentHooks,
                    toolName, argsJson: string): string =
  ## Runs a built-in tool (todo_write, write_file, read_file, list_files),
  ## records it like any other tool call and returns the result JSON.
  let benv = BuiltinEnv(db: env.db, dataDir: env.dataDir, convId: convId, messageId: assistantMsgId)
  let res = runBuiltin(benv, toolName, argsJson)
  let status = if res.ok: $tcsSucceeded else: $tcsFailed
  let tcId = env.db.createToolCall(assistantMsgId, toolName, argsJson)
  env.db.setToolCallResult(tcId, status, res.resultJson)
  for ev in res.events:
    hooks.emit(ev)
  hooks.emit(%*{"type": "tool_call_result", "id": tcId, "name": toolName, "args": argsJson,
                "status": status, "result": res.resultJson})
  result = res.resultJson

proc runSubAgentCall(env: LoopEnv, convId, assistantMsgId: int64, hooks: AgentHooks,
                     sess: ChatSession, argsJson: string): Future[string] {.async.} =
  ## Executes `spawn_subagent`: runs the sub-agent to completion (streaming its
  ## progress through `hooks`) and returns the result JSON for the parent.
  let tcId = env.db.createToolCall(assistantMsgId, subagentToolName, argsJson)
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
    let senv = SubAgentEnv(db: env.db, api: env.api, registry: env.registry,
      executor: env.executor, dataDir: env.dataDir, promptFile: env.promptFile, convId: convId,
      parentMessageId: assistantMsgId, model: sess.entry, hooks: hooks)
    var res = SubAgentResult(ok: false, report: "", error: "", rounds: 0)
    try:
      res = await runSubAgent(senv, a["task"].getStr(), a{"context"}.getStr(""), allow)
    except CatchableError as e:
      res.error = e.msg
      logError("subagent", "crashed: " & $e.name & ": " & e.msg)
    if res.ok:
      status = $tcsSucceeded
      outJson = $(%*{"ok": true, "data": {"report": res.report, "rounds": res.rounds}})
    else:
      let reason = if res.error.len > 0: res.error else: "the sub-agent failed"
      outJson = $(%*{"ok": false, "error": reason})
  env.db.setToolCallResult(tcId, status, outJson)
  hooks.emit(%*{"type": "tool_call_result", "id": tcId, "name": subagentToolName,
                "args": argsJson, "status": status, "result": outJson})
  result = outJson

proc runAgentTurn*(env: LoopEnv, convId: int64, sess: ChatSession,
                   hooks: AgentHooks): Future[TurnResult] {.async.} =
  ## Runs the loop for the conversation's latest user message. Persists the
  ## assistant/reasoning/tool messages; streams `assistant_token`,
  ## `reasoning_token`, `tool_call_result`, ... through `hooks.emit`. The
  ## returned reply carries the visible final text (tool-call tags stripped).
  while true:
    let history = buildHistory(env, convId, sess.entry.images)
    result.history = history
    logInfo("api", "sendTurn model=" & sess.model & " messages=" & $history.len)
    let onToken = proc(tok: string): Future[void] {.gcsafe.} =
      hooks.emit(%*{"type": "assistant_token", "content": tok})
      result = newFuture[void]("onToken")
      result.complete()
    let onReasoning = proc(tok: string): Future[void] {.gcsafe.} =
      hooks.emit(%*{"type": "reasoning_token", "content": tok})
      result = newFuture[void]("onReasoning")
      result.complete()
    let reply = await sess.sendTurnStreaming(history, onToken, onReasoning, hooks.isCancelled)
    hooks.emit(%*{"type": "usage", "used": sess.promptTokens + sess.completionTokens, "ctx": sess.ctxSize})

    if reply.reasoning.len > 0:
      discard env.db.addMessage(convId, none(int64), "reasoning", reply.reasoning)

    let calls = parseToolCalls(reply.content, env.registry)
    if calls.len == 0 or hooks.isCancelled():
      let visible = stripToolCalls(reply.content)
      if visible.len > 0:
        discard env.db.addMessage(convId, none(int64), "assistant", visible)
      result.reply = StreamingReply(content: visible, reasoning: reply.reasoning, error: reply.error)
      return

    let assistantMsgId = env.db.addMessage(convId, none(int64), "assistant", reply.content)
    for call in calls:
      var resultJson = ""
      if call.malformed:
        resultJson = $(%*{"ok": false, "error": call.error})
      elif hooks.isCancelled():
        resultJson = $(%*{"ok": false, "error": "cancelled"})
      elif call.name == subagentToolName:
        resultJson = await runSubAgentCall(env, convId, assistantMsgId, hooks, sess, call.argsJson)
      elif isBuiltin(call.name):
        resultJson = runBuiltinCall(env, convId, assistantMsgId, hooks, call.name, call.argsJson)
      else:
        let d = await env.executor.dispatchToolCall(convId, assistantMsgId, call.name,
                                                     call.argsJson, hooks.askApproval)
        resultJson = if d.resultJson.len > 0: d.resultJson else: $(%*{"ok": false, "error": d.status})
        hooks.emit(%*{"type": "tool_call_result", "id": d.id, "name": call.name,
                      "args": call.argsJson, "status": d.status, "result": d.resultJson})
      discard env.db.addMessage(convId, none(int64), "tool", resultJson)
    if hooks.isCancelled():
      result.reply = StreamingReply(content: "", reasoning: "", error: "")
      return
