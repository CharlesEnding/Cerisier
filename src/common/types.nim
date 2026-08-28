## Shared types used by both the `cerisier-server` and `cerisier-agent` binaries.
##
## Kept dependency-free (stdlib only) so both binaries can import it cheaply.

import std/[options, times]

type
  ToolLocation* = enum
    tlLocal = "local"     ## runs on the machine where the web interface is accessed
    tlRemote = "remote"   ## runs on the machine hosting the server / llama.cpp

  ToolKind* = enum
    tkNimBinary = "nim-binary"
    tkPython = "python"
    tkShell = "shell"

  ToolManifest* = object
    name*: string
    description*: string
    kind*: ToolKind
    location*: ToolLocation
    entrypoint*: string       ## path to binary / script, or the shell command template
    inputSchema*: string      ## raw JSON schema describing accepted parameters
    timeoutMs*: int
    autoRun*: bool            ## if true, skip the approval gate (opt-in, defaults false)

  ToolCallStatus* = enum
    tcsPendingApproval = "pending_approval"
    tcsApproved = "approved"
    tcsRunning = "running"
    tcsSucceeded = "succeeded"
    tcsFailed = "failed"
    tcsTimeout = "timeout"
    tcsDenied = "denied"

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

  ModelOpResult* = object
    ## Result of a load/unload call against the router: `success` mirrors
    ## the router's own `success` field, `error` carries whatever error
    ## detail we could extract (router-provided message, or the transport
    ## exception's message if the request itself failed).
    success*: bool
    error*: string
