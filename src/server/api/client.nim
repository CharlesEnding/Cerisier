## Async client for an OpenAI-compatible `/v1` server (Edge, llama-server, or
## the future Cerisier router). Chat requests, SSE streaming and model
## listing are plain OpenAI; load/unload are optional extras that only exist
## on servers that implement them (see `Config.modelManagement`).

import std/[httpclient, json, uri, strformat, strutils, asyncdispatch, asyncnet, options]
import ../../common/types
import ../log

type
  ApiClient* = ref object
    host: string
    port: int
    basePath: string    ## path prefix of the API, e.g. "/v1"
    apiKey: string

proc newApiClient*(apiUrl, apiKey: string): ApiClient =
  ## `apiUrl` is the API base including its prefix, e.g. `http://host:8000/v1`.
  ## No request carries a fixed timeout: generation time is unbounded
  ## (depends on prompt size, model, hardware), so a timeout would only
  ## produce spurious failures.
  let u = parseUri(apiUrl)
  if u.scheme != "http":
    raise newException(ValueError, "api_url must be http:// (streaming has no TLS support): " & apiUrl)
  if u.hostname.len == 0:
    raise newException(ValueError, "api_url has no host: " & apiUrl)
  ApiClient(
    host: u.hostname,
    port: (if u.port.len > 0: parseInt(u.port) else: 80),
    basePath: u.path.strip(chars = {'/'}, leading = false),
    apiKey: apiKey,
  )

proc url(rc: ApiClient, path: string): string =
  &"http://{rc.host}:{rc.port}{rc.basePath}{path}"

proc authHeaders(rc: ApiClient, json = false): HttpHeaders =
  result = newHttpHeaders()
  if json:
    result["Content-Type"] = "application/json"
  if rc.apiKey.len > 0:
    result["Authorization"] = "Bearer " & rc.apiKey

proc extractErrorMsg(resp: JsonNode): string =
  ## Error bodies aren't consistently shaped: a flat `{"error": "..."}`
  ## string, or OpenAI-style nested `{"error": {"message": ..., "type": ...}}`.
  let errNode = resp{"error"}
  if errNode != nil:
    if errNode.kind == JString:
      return errNode.getStr("")
    elif errNode.kind == JObject:
      let msg = errNode{"message"}.getStr("")
      let typ = errNode{"type"}.getStr("")
      if msg.len > 0 or typ.len > 0:
        return (if msg.len > 0: msg else: "") & (if typ.len > 0: " (" & typ & ")" else: "")
  result = resp{"message"}.getStr(resp{"detail"}.getStr(""))

proc parseReply(code: HttpCode, body: string): JsonNode =
  ## Parses a JSON reply; raises with the server's own message on a non-2xx
  ## status or an unparseable body.
  var node: JsonNode = nil
  try:
    node = parseJson(body)
  except CatchableError:
    discard
  if not is2xx(code):
    let detail = if node != nil: extractErrorMsg(node) else: ""
    raise newException(CatchableError, $code & ": " & (if detail.len > 0: detail else: body.strip()))
  if node == nil:
    raise newException(CatchableError, $code & ": " & body.strip())
  node

proc get(rc: ApiClient, path: string): Future[JsonNode] {.async.} =
  ## A fresh async client per call (a reused one can hold a socket the server
  ## has since closed). Must stay async: a sync call would freeze the whole
  ## single-threaded server for its duration.
  let client = newAsyncHttpClient()
  defer: client.close()
  client.headers = rc.authHeaders()
  let response = await client.request(rc.url(path), httpMethod = HttpGet)
  let body = await response.body
  logInfo("api", "GET " & path & " -> " & $response.code)
  parseReply(response.code, body)

proc postJson*(rc: ApiClient, path: string, body: JsonNode): Future[JsonNode] {.async.} =
  let client = newAsyncHttpClient()
  defer: client.close()
  client.headers = rc.authHeaders(json = true)
  let response = await client.request(rc.url(path), httpMethod = HttpPost, body = $body)
  let respBody = await response.body
  logInfo("api", "POST " & path & " -> " & $response.code)
  parseReply(response.code, respBody)

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

proc streamSse*(rc: ApiClient, path: string, body: JsonNode,
                onData: proc(payload: string): Future[void] {.gcsafe.},
                isCancelled: proc(): bool {.gcsafe.}): Future[void] {.async, gcsafe.} =
  ## POSTs `body` and reads the Server-Sent Events reply over a raw async
  ## socket, awaiting `onData` with the payload of each `data:` line as it
  ## arrives (the terminating `[DONE]` is not passed on). Raises with the
  ## server's message on a non-2xx status. No read timeout: generation time
  ## is unbounded. `isCancelled` is polled between lines.
  let payload = $body
  let socket = newAsyncSocket()
  var buf = LineBuf(data: "")
  try:
    let fullPath = rc.basePath & path
    logInfo("api", &"connecting to {rc.host}:{rc.port} for {fullPath}")
    await socket.connect(rc.host, Port(rc.port))
    let auth = if rc.apiKey.len > 0: "Authorization: Bearer " & rc.apiKey & "\r\n" else: ""
    let request = &"POST {fullPath} HTTP/1.1\r\nHost: {rc.host}:{rc.port}\r\n" & auth &
      &"Content-Type: application/json\r\nContent-Length: {payload.len}\r\n" &
      "Connection: close\r\n\r\n" & payload
    await socket.send(request)
    logInfo("api", &"request sent ({payload.len} bytes), awaiting response")
    let statusLine = await nextLine(socket, buf)
    if statusLine.isNone:
      raise newException(IOError, "connection closed before an HTTP response was received")
    let parts = statusLine.get().strip().split(' ', maxsplit = 2)
    let code = if parts.len >= 2: parseInt(parts[1]) else: 0
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
    if code < 200 or code >= 300:
      var errBody = ""
      while errBody.len < 8192:
        let lineOpt = await nextLine(socket, buf)
        if lineOpt.isNone:
          break
        errBody.add(lineOpt.get() & "\n")
      var detail = errBody.strip()
      try:
        let m = extractErrorMsg(parseJson(detail))
        if m.len > 0:
          detail = m
      except CatchableError:
        discard
      raise newException(CatchableError, $code & ": " & detail)
    while true:
      if isCancelled():
        logInfo("api", "stream cancelled by caller")
        break
      let lineOpt = await nextLine(socket, buf)
      if lineOpt.isNone:
        break ## socket closed
      let trimmed = lineOpt.get().strip()
      if trimmed.len == 0 or not trimmed.startsWith("data:"):
        continue
      let data = trimmed[5 .. ^1].strip()
      if data == "[DONE]":
        break
      await onData(data)
  finally:
    socket.close()

proc postJsonStream*(rc: ApiClient, path: string, body: JsonNode,
                      onToken: proc(chunk: string): Future[void] {.gcsafe.},
                      onReasoning: proc(chunk: string): Future[void] {.gcsafe.},
                      isCancelled: proc(): bool {.gcsafe.}): Future[JsonNode] {.async, gcsafe.} =
  ## Streams a chat completion, awaiting `onToken`/`onReasoning` for each
  ## incremental fragment so callers can push tokens out immediately.
  ## Returns `{content, reasoning, usage?, error?}`.
  var fullText = ""
  var fullReasoning = ""
  var lastUsage: JsonNode = nil
  var streamError = ""
  var chunkCount = 0
  let onData = proc(data: string): Future[void] {.async, gcsafe.} =
    let node = parseJson(data)
    let errNode = node{"error"}
    if errNode != nil:
      streamError = extractErrorMsg(node)
      if streamError.len == 0:
        streamError = $errNode
      logError("api", &"stream returned an error payload: {streamError}")
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
        # Reasoning models emit thinking text under `reasoning_content`
        # (some servers use `reasoning`).
        var reasoningPiece = delta{"reasoning_content"}.getStr("")
        if reasoningPiece.len == 0:
          reasoningPiece = delta{"reasoning"}.getStr("")
        if reasoningPiece.len > 0:
          fullReasoning.add(reasoningPiece)
          await onReasoning(reasoningPiece)
    let usage = node{"usage"}
    if usage != nil and usage.kind == JObject:
      lastUsage = usage
  let stop = proc(): bool {.gcsafe.} = isCancelled() or streamError.len > 0
  await rc.streamSse(path, body, onData, stop)
  logInfo("api", &"stream done: {chunkCount} chunk(s), {fullText.len} char(s) total")
  result = %*{"content": fullText, "reasoning": fullReasoning}
  if streamError.len > 0:
    result["error"] = %streamError
  if lastUsage != nil:
    result["usage"] = lastUsage

proc probe*(rc: ApiClient): Future[string] {.async.} =
  ## "" when the backend answers `GET /models`, else why it didn't.
  try:
    discard await rc.get("/models")
    ""
  except CatchableError as e:
    e.msg

proc modelStatusFromJson(node: JsonNode): ModelStatus =
  ## Plain OpenAI servers carry no status, so a listed model counts as loaded.
  let id = node{"id"}.getStr("")
  let statusVal = node{"status"}{"value"}.getStr("loaded")
  let status =
    case statusVal
    of "loaded": msvLoaded
    of "loading": msvLoading
    of "sleeping": msvSleeping
    of "downloading": msvDownloading
    else: msvUnloaded
  ModelStatus(id: id, status: status, supportsVision: false, contextSize: 0)

proc listModels*(rc: ApiClient): Future[seq[ModelStatus]] {.async.} =
  let root = await rc.get("/models")
  result = @[]
  let data = root{"data"}
  if data != nil and data.kind == JArray:
    for node in data:
      result.add(modelStatusFromJson(node))
  logInfo("api", "GET /models -> " & $result.len & " model(s)")

# Optional model management: only servers that implement these endpoints
# (a llama-server router, the future Cerisier router) can honour them.

proc modelOp(rc: ApiClient, op, modelId: string): Future[ModelOpResult] {.async.} =
  try:
    let resp = await rc.postJson("/models/" & op, %*{"model": modelId})
    let success = resp{"success"}.getBool(false)
    var errMsg = ""
    if not success:
      errMsg = extractErrorMsg(resp)
      if errMsg.len == 0:
        errMsg = "server declined to " & op & " model (no reason given): " & $resp
    result = ModelOpResult(success: success, error: errMsg)
  except CatchableError as e:
    result = ModelOpResult(success: false, error: e.msg)
  if result.success:
    logInfo("api", "POST /models/" & op & " model=" & modelId & " success=true")
  else:
    logError("api", "POST /models/" & op & " model=" & modelId & " failed: " & result.error)

proc loadModel*(rc: ApiClient, modelId: string): Future[ModelOpResult] =
  rc.modelOp("load", modelId)

proc unloadModel*(rc: ApiClient, modelId: string): Future[ModelOpResult] =
  rc.modelOp("unload", modelId)
