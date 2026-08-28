## Typed HTTP client wrapping the llama-server router-mode API.
## Compile-only verification project: no live router is expected to be
## reachable on this dev machine, so all calls are behind explicit procs
## that a caller can choose not to invoke; nothing here executes at
## module-import time.

import std/[httpclient, json, uri, strformat, strutils, asyncdispatch, asyncnet]
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

proc postJsonStream*(rc: RouterClient, path: string, body: JsonNode,
                      onChunk: proc(chunk: string): Future[void] {.gcsafe.},
                      isCancelled: proc(): bool {.gcsafe.}): Future[JsonNode] {.async, gcsafe.} =
  ## Streams a chat-completion style POST as Server-Sent Events over a raw
  ## async socket, awaiting `onChunk` for each incremental assistant text
  ## fragment as it arrives so callers (e.g. a WebSocket handler) can push
  ## tokens out immediately instead of buffering the whole reply. No read
  ## timeout is applied anywhere in this call — generation time is
  ## unbounded. `isCancelled` is polled between SSE lines so a caller can
  ## abort a long-running generation early.
  let payload = $body
  let socket = newAsyncSocket()
  var fullText = ""
  var lastUsage: JsonNode = nil
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
      let line = await socket.recvLine()
      if line.len == 0:
        break ## connection closed before headers finished
      if line.strip().len == 0:
        sawHeaders = true
        break
    if not sawHeaders:
      raise newException(IOError, "connection closed before HTTP headers were received")
    var chunkCount = 0
    while true:
      if isCancelled():
        logInfo("router", "generation cancelled by caller")
        break
      let line = await socket.recvLine()
      if line.len == 0:
        break ## socket closed
      let trimmed = line.strip()
      if trimmed.len == 0 or not trimmed.startsWith("data:"):
        continue
      let jsonPayload = trimmed[5 .. ^1].strip()
      if jsonPayload == "[DONE]":
        break
      let node = parseJson(jsonPayload)
      let choices = node{"choices"}
      if choices != nil and choices.kind == JArray and choices.len > 0:
        let delta = choices[0]{"delta"}
        if delta != nil:
          let piece = delta{"content"}.getStr("")
          if piece.len > 0:
            fullText.add(piece)
            inc chunkCount
            await onChunk(piece)
      let usage = node{"usage"}
      if usage != nil:
        lastUsage = usage
    logInfo("router", &"stream done: {chunkCount} chunk(s), {fullText.len} char(s) total")
  finally:
    socket.close()
  result = %*{"content": fullText}
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

proc loadModel*(rc: RouterClient, modelId: string): bool =
  let body = %*{"model": modelId}
  let resp = rc.postJson("/models/load", body)
  result = resp{"success"}.getBool(false)
  logInfo("router", "POST /models/load model=" & modelId & " success=" & $result)

proc unloadModel*(rc: RouterClient, modelId: string): bool =
  let body = %*{"model": modelId}
  let resp = rc.postJson("/models/unload", body)
  result = resp{"success"}.getBool(false)
  logInfo("router", "POST /models/unload model=" & modelId & " success=" & $result)

proc props*(rc: RouterClient, modelId: string = ""): JsonNode =
  let path = if modelId.len > 0: "/props?model=" & encodeUrl(modelId) else: "/props"
  rc.get(path)
