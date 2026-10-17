## Shared types used by both the `cerisier-server` and `cerisier-agent` binaries.
##
## Kept dependency-free (stdlib only) so both binaries can import it cheaply.

import std/[options, times]

type
  ToolLocation* = enum
    ## The *manifest* setting. NOTE: the legacy names are misleading, so what
    ## they actually do at runtime is pinned down in `manifestTarget` below:
    ## `local` = executed by the server process itself (osproc on the server
    ## host), `remote` = dispatched to a connected cerisier-agent companion.
    tlLocal = "local"
    tlRemote = "remote"

  ExecTarget* = enum
    ## Where a tool call actually executes. This is the unambiguous vocabulary
    ## used by the chat UI ("Run tools on: Per tool / Server / Client").
    etServer = "server"   ## the machine hosting cerisier-server (and llama.cpp)
    etClient = "client"   ## the machine where the web interface is accessed, via cerisier-agent

  ToolTargetPref* = enum
    ## Per-conversation override of where tools run.
    ttpDefault = "default"  ## each tool uses its own manifest `location`
    ttpServer = "server"    ## force every tool onto the server
    ttpClient = "client"    ## force every tool onto the client agent

  ToolKind* = enum
    tkNimBinary = "nim-binary"
    tkPython = "python"
    tkShell = "shell"

  ToolPermission* = enum
    ptAuto = "auto"     ## runs immediately, no chat interaction needed
    ptAsk = "ask"       ## default: pending_approval row + chat approve/deny UI
    ptDeny = "deny"     ## registered/discoverable but never dispatchable

  ToolManifest* = object
    name*: string
    description*: string
    kind*: ToolKind
    location*: ToolLocation
    entrypoint*: string       ## path to binary / script, or the shell command template
    inputSchema*: string      ## raw JSON schema describing accepted parameters
    outputSchema*: string     ## raw JSON schema describing the `data` field of a successful result
    timeoutMs*: int
    permission*: ToolPermission

  ToolCallStatus* = enum
    tcsPendingApproval = "pending_approval"
    tcsApproved = "approved"
    tcsRunning = "running"
    tcsSucceeded = "succeeded"
    tcsFailed = "failed"
    tcsTimeout = "timeout"
    tcsDenied = "denied"
    tcsKilled = "killed"
    tcsValidationFailed = "validation_failed"
    tcsProtocolError = "protocol_error"

  ToolCall* = object
    id*: int64
    messageId*: int64
    toolName*: string
    location*: ToolLocation
    argsJson*: string         ## exact parameter values, shown to the user for approval
    status*: ToolCallStatus
    resultJson*: Option[string]
    createdAt*: DateTime

  MessageRole* = enum
    mrSystem = "system"
    mrUser = "user"
    mrAssistant = "assistant"
    mrTool = "tool"
    mrReasoning = "reasoning"

  AgentMessage* = object
    id*: int64
    conversationId*: int64
    parentId*: Option[int64]  ## nil for top-level messages; set for sub-conversation nodes
    role*: MessageRole
    content*: string
    createdAt*: DateTime

  ModelStatusValue* = enum
    msvUnloaded = "unloaded"
    msvLoading = "loading"
    msvLoaded = "loaded"
    msvSleeping = "sleeping"
    msvDownloading = "downloading"

  ModelStatus* = object
    id*: string              ## model id / alias as known to the router
    status*: ModelStatusValue
    supportsVision*: bool
    contextSize*: int

proc manifestTarget*(loc: ToolLocation): ExecTarget =
  ## SINGLE SOURCE OF TRUTH for how a manifest's `location` maps to a target.
  ## This preserves the behaviour the executor had before the chat-level
  ## option existed (`local` ran on the server host, `remote` needed a
  ## companion). If you would rather have `local` mean "the client machine"
  ## (as the old doc comment on ToolLocation claimed), swap the two arms.
  case loc
  of tlLocal: etServer
  of tlRemote: etClient

proc resolveTarget*(pref: ToolTargetPref, loc: ToolLocation): ExecTarget =
  case pref
  of ttpServer: etServer
  of ttpClient: etClient
  of ttpDefault: manifestTarget(loc)

type
  ModelOpResult* = object
    ## Result of a load/unload call against the router: `success` mirrors
    ## the router's own `success` field, `error` carries whatever error
    ## detail we could extract (router-provided message, or the transport
    ## exception's message if the request itself failed).
    success*: bool
    error*: string
