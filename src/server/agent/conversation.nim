## Orchestrates the hierarchical "agent conversation" and its child llama
## sessions. Decouples the (potentially infinite) agent conversation from
## bounded llama.cpp chat sessions: a sub-task (e.g. one image out of many)
## gets its own child LlamaSession, whose result is compiled back into the
## parent as a message.

import std/[options, os, strformat]
import ../db/database
import ../llama/router_client
import ../llama/session

type
  ConversationOrchestrator* = ref object
    db: Database
    router: RouterClient

proc newOrchestrator*(db: Database, router: RouterClient): ConversationOrchestrator =
  ConversationOrchestrator(db: db, router: router)

proc startConversation*(orch: ConversationOrchestrator, title: string): int64 =
  orch.db.createConversation(title)

proc appendMessage*(orch: ConversationOrchestrator, conversationId: int64,
                     parentId: Option[int64], role, content: string): int64 =
  orch.db.addMessage(conversationId, parentId, role, content)

proc spawnChildSession*(orch: ConversationOrchestrator, conversationId: int64,
                         parentMessageId: int64, model, purpose: string, ctxSize: int): LlamaSession =
  ## Opens a fresh bounded llama session scoped to a single sub-task,
  ## attached under `parentMessageId` in the agent conversation tree.
  newLlamaSession(orch.db, orch.router, conversationId, some(parentMessageId), model, purpose, ctxSize)

proc compileChildResults*(orch: ConversationOrchestrator, conversationId: int64,
                           parentMessageId: int64, childResults: seq[string]): int64 =
  ## Synthesizes N child-session results into one message appended under
  ## the parent, giving the parent conversation a global view without
  ## re-ingesting every child's full context.
  var synthesis = "Synthesis of " & $childResults.len & " sub-conversation(s):\n\n"
  for i, r in childResults:
    synthesis.add(&"[{i + 1}] {r}\n")
  orch.appendMessage(conversationId, some(parentMessageId), "assistant", synthesis)

## Example driving use case (see plan Phase 2 step 4): analysing every image
## in a folder without blowing the parent conversation's context budget.
proc analyzeImagesInFolder*(orch: ConversationOrchestrator, conversationId: int64,
                             parentMessageId: int64, folder: string, visionModel: string,
                             ctxSizePerImage: int): int64 =
  var results: seq[string] = @[]
  if dirExists(folder):
    for path in walkFiles(folder / "*"):
      let child = orch.spawnChildSession(conversationId, parentMessageId, visionModel,
                                          "analyze image: " & path, ctxSizePerImage)
      # Actual multimodal call happens via child.sendTurn(...) once a router
      # is reachable; left as a caller responsibility so this proc stays
      # testable/compilable without a live model.
      results.add("(pending analysis) " & path)
      discard child
  orch.compileChildResults(conversationId, parentMessageId, results)
