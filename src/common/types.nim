## Shared types used across the server modules. Stdlib only.

import std/[options, times]

type
  ToolKind* = enum
    tkNimBinary = "nim-binary"
    tkPython = "python"
    tkShell = "shell"

  ToolPermission* = enum
    ptAuto = "auto"     ## runs immediately, no chat interaction needed
    ptAutoWorkdir = "auto_workdir"  ## auto only if every declared path arg resolves under the
                                    ## conversation's working directory (see isWithinWorkingDir in
                                    ## executor.nim); otherwise falls back to the normal `ask` gate
    ptAsk = "ask"       ## default: pending_approval row + chat approve/deny UI
    ptDeny = "deny"     ## registered/discoverable but never dispatchable

  ToolManifest* = object
    name*: string
    description*: string
    kind*: ToolKind
    entrypoint*: string       ## path to binary / script, or the shell command template
    inputSchema*: string      ## raw JSON schema describing accepted parameters
    outputSchema*: string     ## raw JSON schema describing the `data` field of a successful result
    timeoutMs*: int
    permission*: ToolPermission
    pathArgs*: seq[string]    ## names of input fields holding filesystem paths; used by the
                              ## auto_workdir gate to decide whether the call stays inside the
                              ## conversation's working directory
    viewJson*: string         ## raw JSON of the manifest's optional "view" block, describing
                              ## how the chat client renders this tool's args/result (see views.js).
                              ## Empty string when the tool declares none.

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

type
  ModelOpResult* = object
    ## Result of a load/unload call: `success` mirrors the server's own
    ## `success` field, `error` carries the server's message or the
    ## transport exception's message.
    success*: bool
    error*: string
