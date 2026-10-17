## Sub-agents: offload a self-contained task to a fresh, bounded llama session
## so the main conversation's context isn't eaten by the work.
##
## A sub-agent has its own LlamaSession (child of the assistant message that
## called `spawn_subagent`), starts with an empty context containing only its
## task, may use tools (same permission/approval model as the main agent; no
## recursion, no todo list), and returns ONE final report to the parent.
##
## Persistence: the task is stored as a `user` message whose parent is the
## spawning assistant message; everything the sub-agent says or does is stored
## beneath that task message. The main history ignores messages that have a
## parent, which is what keeps the parent's context small.
##
## UI events go through `hooks.emit` so the web layer can order them with the
## rest of the WebSocket traffic; approvals use `hooks.askApproval`.

import std/[json, options, strutils, asyncdispatch]
import ../db/database
import ../llama/router_client
import ../llama/session
import ../tools/registry
import ../tools/executor
import ../tools/builtin
import ../tools/toolcalls
import ../log
import ../../common/types
import ./prompt

const
  subAgentInstructions = """## You are a sub-agent
You were started by a parent assistant to do one task, and you only know what is in the task below. Do the task, using tools if you need them), then reply with a concise final report containing only what the parent needs: findings, names of any files you wrote, and caveats. Do not ask questions; make reasonable assumptions and state them. Your reply without a tool call is your final report."""

type
  SubAgentHooks* = ref object
    emit*: proc(ev: JsonNode) {.gcsafe.}
    askApproval*: ApprovalHook
    isCancelled*: proc(): bool {.gcsafe.}

  SubAgentEnv* = ref object
    db*: Database
    router*: RouterClient
    registry*: ToolRegistry
    executor*: ToolExecutor
    dataDir*: string
    convId*: int64
    parentMessageId*: int64   ## assistant message that issued spawn_subagent
    model*: string
    ctxSize*: int
    hooks*: SubAgentHooks

  SubAgentResult* = object
    ok*: bool
    report*: string
    error*: string
    rounds*: int

proc runSubAgent*(env: SubAgentEnv, task, context: string, allow: seq[string]): Future[SubAgentResult] {.async.} =
  let db = env.db
  var fullTask = task.strip()
  if context.strip().len > 0:
    fullTask.add("\n\nContext:\n" & context.strip())

  let rootId = db.addMessage(env.convId, some(env.parentMessageId), "user", fullTask)
  let sess = newLlamaSession(db, env.router, env.convId, some(rootId), env.model, "subagent", env.ctxSize)
  discard db.addTurn(sess.id, "user", fullTask)
  logInfo("subagent", "started (task " & $fullTask.len & " chars, model " & env.model & ")")
  env.hooks.emit(%*{"type": "subagent_start", "id": rootId, "task": fullTask})

  let systemPrompt = buildSystemPrompt(db, env.registry, env.convId, forSubAgent = true, allow = allow) &
    "\n\n" & subAgentInstructions
  var history: seq[ChatMsg] = @[chatMsg("system", systemPrompt), chatMsg("user", fullTask)]
  var res = SubAgentResult(ok: false, report: "", error: "", rounds: 0)

  let isCancelled = proc(): bool {.gcsafe.} =
    env.hooks.isCancelled()

  try:
    var round = 0
    while true:
      let onToken = proc(tok: string): Future[void] {.gcsafe.} =
        env.hooks.emit(%*{"type": "subagent_token", "id": rootId, "content": tok})
        result = newFuture[void]("subAgentToken")
        result.complete()
      let onReasoning = proc(tok: string): Future[void] {.gcsafe.} =
        env.hooks.emit(%*{"type": "subagent_reasoning", "id": rootId, "content": tok})
        result = newFuture[void]("subAgentReasoning")
        result.complete()

      let reply = await sess.sendTurnStreaming(history, onToken, onReasoning, isCancelled)
      inc round
      res.rounds = round

      if reply.reasoning.len > 0:
        discard db.addMessage(env.convId, some(rootId), "reasoning", reply.reasoning)
      if env.hooks.isCancelled():
        res.error = "cancelled"
        break
      if reply.content.len == 0:
        res.error = if reply.error.len > 0: reply.error else: "the sub-agent returned an empty reply"
        break

      let calls = parseToolCalls(reply.content)
      let visible = stripToolCalls(reply.content)
      if calls.len == 0:
        discard db.addMessage(env.convId, some(rootId), "assistant", visible)
        res.ok = true
        res.report = visible
        break

      let assistantMsgId = db.addMessage(env.convId, some(rootId), "assistant", reply.content)
      history.add(chatMsg("assistant", reply.content))

      for call in calls:
        var resultJson = ""
        if call.malformed:
          resultJson = $(%*{"ok": false, "error": call.error})
        elif env.hooks.isCancelled():
          resultJson = $(%*{"ok": false, "error": "cancelled"})
        elif isBuiltin(call.name):
          let spec = findBuiltin(call.name).get()
          if not spec.subAgentOk:
            resultJson = $(%*{"ok": false, "error": "the tool '" & call.name & "' is not available to sub-agents"})
          else:
            let r = runBuiltin(BuiltinEnv(db: db, dataDir: env.dataDir, convId: env.convId,
                                          messageId: assistantMsgId), call.name, call.argsJson)
            resultJson = r.resultJson
            let status = if r.ok: $tcsSucceeded else: $tcsFailed
            let tcId = db.createToolCall(assistantMsgId, call.name, $etServer, call.argsJson)
            db.setToolCallResult(tcId, status, resultJson)
            for ev in r.events:
              env.hooks.emit(ev)
            env.hooks.emit(%*{"type": "tool_call_result", "id": tcId, "name": call.name,
                              "args": call.argsJson, "status": status, "result": resultJson})
        elif allow.len > 0 and call.name notin allow:
          resultJson = $(%*{"ok": false, "error": "the tool '" & call.name & "' is not available to this sub-agent"})
        else:
          let d = await env.executor.dispatchToolCall(env.convId, assistantMsgId, call.name,
                                                       call.argsJson, env.hooks.askApproval)
          resultJson = if d.resultJson.len > 0: d.resultJson else: $(%*{"ok": false, "error": d.status})
          env.hooks.emit(%*{"type": "tool_call_result", "id": d.id, "name": call.name,
                            "args": call.argsJson, "status": d.status, "result": resultJson})
        discard db.addMessage(env.convId, some(rootId), "tool", resultJson)
        discard db.addTurn(sess.id, "tool", resultJson)
        history.add(chatMsg("tool", resultJson))
  except CatchableError as e:
    res.ok = false
    res.error = e.msg
    logError("subagent", "failed: " & $e.name & ": " & e.msg)

  db.closeSession(sess.id, "closed")
  env.hooks.emit(%*{"type": "subagent_end", "id": rootId, "ok": res.ok})
  logInfo("subagent", "finished ok=" & $res.ok & " rounds=" & $res.rounds)
  result = res
