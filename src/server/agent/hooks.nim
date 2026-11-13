## How an agent loop talks to whatever drives it (the web UI, the HTTP API).
## Everything goes through `emit` so events stay in order with streamed tokens.

import std/json
import ../tools/executor

type
  AgentHooks* = ref object
    emit*: proc(ev: JsonNode) {.gcsafe.}
    askApproval*: ApprovalHook
    isCancelled*: proc(): bool {.gcsafe.}
