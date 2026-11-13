## Creates agent conversations and appends messages to them. Sub-tasks live
## under a parent message (see subagent.nim) and have their own ChatSession.

import std/options
import ../db/database

type
  ConversationOrchestrator* = ref object
    db: Database

proc newOrchestrator*(db: Database): ConversationOrchestrator =
  ConversationOrchestrator(db: db)

proc startConversation*(orch: ConversationOrchestrator, title: string): int64 =
  orch.db.createConversation(title)

proc appendMessage*(orch: ConversationOrchestrator, conversationId: int64,
                     parentId: Option[int64], role, content: string): int64 =
  orch.db.addMessage(conversationId, parentId, role, content)
