## Typed HTTP client wrapping the llama-server router-mode API.
## Compile-only verification project: no live router is expected to be
## reachable on this dev machine, so all calls are behind explicit procs
## that a caller can choose not to invoke; nothing here executes at
## module-import time.

import std/[httpclient, json, uri, strformat, strutils, asyncdispatch, asyncnet, options]
import ../../common/types
import ../log

type
  RouterClient* = ref object
    baseUrl: string
    host: string
    port: int

proc newRouterClient*(host: string, port: int): RouterClient =
  ## No request made by this client carries a fixed timeout: llama-server
  ## generation time is unbounded (depends on prompt size, model, hardware),
  ## so imposing a timeout here just produces spurious failures. Callers
  ## that want a "is the router even up" check should use `health()`, which
  ## fails fast on connection refused without needing a read timeout.
  RouterClient(
    baseUrl: &"http://{host}:{port}",
    host: host,
    port: port,
  )

proc get(rc: RouterClient, path: string): JsonNode =
  ## Uses a fresh HttpClient per call: a single reused client can end up
  ## holding a socket that llama-server has since closed, causing
  ## intermittent "Connection was closed before full request has been
  ## made" errors. No timeout is set (see `newRouterClient`).
  let client = newHttpClient(timeout = -1)
  defer: client.close()
  let resp = client.getContent(rc.baseUrl & path)
  parseJson(resp)

proc postJson*(rc: RouterClient, path: string, body: JsonNode): JsonNode =
  let client = newHttpClient(timeout = -1)
  defer: client.close()
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  let resp = client.postContent(rc.baseUrl & path, $body)
  parseJson(resp)

type
  LineBuf = ref object
    data: string

proc nextLine(socket: AsyncSocket, buf: LineBuf): Future[Option[string]] {.async.} =
  ## Buffered line reader over a raw socket. `AsyncSocket.recvLine` reads
  ## one byte at a time internally, which is fine for a short HTTP header
  ## block but tanks throughput badly for a token-per-line SSE stream (this
  ## was the actual cause of slow-feeling streaming — not the endpoint
  ## choice). This reads in 8KB chunks and slices lines out of our own
  ## buffer instead. The buffer is a ref object rather than a `var string`
  ## param: async procs can't capture `var` params as closures.
  while true:
    let idx = buf.data.find('\n')
    if idx >= 0:
      let line = buf.data[0 ..< idx]
      buf.data = buf.data[idx + 1 .. ^1]
      return some(line)
    let chunk = await socket.recv(8192)
    if chunk.len == 0:
      if buf.data.len > 0:
        let line = buf.data
        buf.data = ""
        return some(line)
      return none(string)
    buf.data.add(chunk)

proc postJsonStream*(rc: RouterClient, path: string, body: JsonNode,
                      onToken: proc(chunk: string): Future[void] {.gcsafe.},
                      onReasoning: proc(chunk: string): Future[void] {.gcsafe.},
                      isCancelled: proc(): bool {.gcsafe.}): Future[JsonNode] {.async, gcsafe.} =
  ## Streams a chat-completion style POST as Server-Sent Events over a raw
  ## async socket, awaiting `onToken`/`onReasoning` for each incremental
  ## fragment as it arrives so callers (e.g. a WebSocket handler) can push
  ## tokens out immediately instead of buffering the whole reply. No read
  ## timeout is applied anywhere in this call — generation time is
  ## unbounded. `isCancelled` is polled between SSE lines so a caller can
  ## abort a long-running generation early.
  let payload = $body
  let socket = newAsyncSocket()
  var fullText = ""
  var fullReasoning = ""
  var lastUsage: JsonNode = nil
  var buf = LineBuf(data: "")
  try:
    logInfo("router", &"connecting to {rc.host}:{rc.port} for {path}")
    await socket.connect(rc.host, Port(rc.port))
    let request = &"POST {path} HTTP/1.1\r\nHost: {rc.host}:{rc.port}\r\n" &
      &"Content-Type: application/json\r\nContent-Length: {payload.len}\r\n" &
      "Connection: close\r\n\r\n" & payload
    await socket.send(request)
    logInfo("router", &"request sent ({payload.len} bytes), awaiting response")
    # Skip the HTTP response headers.
    var sawHeaders = false
    while true:
      let lineOpt = await nextLine(socket, buf)
      if lineOpt.isNone:
        break ## connection closed before headers finished
      if lineOpt.get().strip().len == 0:
        sawHeaders = true
        break
    if not sawHeaders:
      raise newException(IOError, "connection closed before HTTP headers were received")
    var chunkCount = 0
    while true:
      if isCancelled():
        logInfo("router", "generation cancelled by caller")
        break
      let lineOpt = await nextLine(socket, buf)
      if lineOpt.isNone:
        break ## socket closed
      let trimmed = lineOpt.get().strip()
      if trimmed.len == 0 or not trimmed.startsWith("data:"):
        continue
      let jsonPayload = trimmed[5 .. ^1].strip()
      if jsonPayload == "[DONE]":
        break
      let node = parseJson(jsonPayload)
      let errNode = node{"error"}
      if errNode != nil:
        let errMsg = errNode.getStr(errNode{"message"}.getStr($errNode))
        logError("router", &"stream returned an error payload: {errMsg}")
        result = %*{"content": fullText, "reasoning": fullReasoning, "error": errMsg}
        return
      let choices = node{"choices"}
      if choices != nil and choices.kind == JArray and choices.len > 0:
        let delta = choices[0]{"delta"}
        if delta != nil:
          let piece = delta{"content"}.getStr("")
          if piece.len > 0:
            fullText.add(piece)
            inc chunkCount
            await onToken(piece)
          # llama.cpp / DeepSeek-style reasoning models emit reasoning text
          # under `reasoning_content` (some servers use `reasoning`).
          var reasoningPiece = delta{"reasoning_content"}.getStr("")
          if reasoningPiece.len == 0:
            reasoningPiece = delta{"reasoning"}.getStr("")
          if reasoningPiece.len > 0:
            fullReasoning.add(reasoningPiece)
            await onReasoning(reasoningPiece)
      let usage = node{"usage"}
      if usage != nil:
        lastUsage = usage
    logInfo("router", &"stream done: {chunkCount} chunk(s), {fullText.len} char(s) total")
  finally:
    socket.close()
  result = %*{"content": fullText, "reasoning": fullReasoning}
  if lastUsage != nil:
    result["usage"] = lastUsage


proc health*(rc: RouterClient): bool =
  try:
    discard rc.get("/health")
    true
  except CatchableError:
    false

proc modelStatusFromJson(node: JsonNode): ModelStatus =
  let id = node{"id"}.getStr("")
  let statusVal = node{"status"}{"value"}.getStr("unloaded")
  let status =
    case statusVal
    of "loaded": msvLoaded
    of "loading": msvLoading
    of "sleeping": msvSleeping
    of "downloading": msvDownloading
    else: msvUnloaded
  let modalities = node{"architecture"}{"input_modalities"}
  var vision = false
  if modalities != nil and modalities.kind == JArray:
    for m in modalities:
      if m.getStr("") == "image":
        vision = true
  ModelStatus(id: id, status: status, supportsVision: vision, contextSize: 0)

proc listModels*(rc: RouterClient): seq[ModelStatus] =
  let root = rc.get("/models")
  result = @[]
  let data = root{"data"}
  if data != nil and data.kind == JArray:
    for node in data:
      result.add(modelStatusFromJson(node))
  logInfo("router", "GET /models -> " & $result.len & " model(s)")

proc loadModel*(rc: RouterClient, modelId: string): ModelOpResult =
  let body = %*{"model": modelId}
  try:
    let resp = rc.postJson("/models/load", body)
    let success = resp{"success"}.getBool(false)
    var errMsg = ""
    if not success:
      errMsg = resp{"error"}.getStr(resp{"message"}.getStr(resp{"detail"}.getStr("router declined to load model (no reason given)")))
    result = ModelOpResult(success: success, error: errMsg)
  except CatchableError as e:
    result = ModelOpResult(success: false, error: e.msg)
  if result.success:
    logInfo("router", "POST /models/load model=" & modelId & " success=true")
  else:
    logError("router", "POST /models/load model=" & modelId & " failed: " & result.error)

proc unloadModel*(rc: RouterClient, modelId: string): ModelOpResult =
  let body = %*{"model": modelId}
  try:
    let resp = rc.postJson("/models/unload", body)
    let success = resp{"success"}.getBool(false)
    var errMsg = ""
    if not success:
      errMsg = resp{"error"}.getStr(resp{"message"}.getStr(resp{"detail"}.getStr("router declined to unload model (no reason given)")))
    result = ModelOpResult(success: success, error: errMsg)
  except CatchableError as e:
    result = ModelOpResult(success: false, error: e.msg)
  if result.success:
    logInfo("router", "POST /models/unload model=" & modelId & " success=true")
  else:
    logError("router", "POST /models/unload model=" & modelId & " failed: " & result.error)

proc props*(rc: RouterClient, modelId: string = ""): JsonNode =
  let path = if modelId.len > 0: "/props?model=" & encodeUrl(modelId) else: "/props"
  rc.get(path)
