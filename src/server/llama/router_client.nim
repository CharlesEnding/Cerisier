## Typed HTTP client wrapping the llama-server router-mode API.
## Compile-only verification project: no live router is expected to be
## reachable on this dev machine, so all calls are behind explicit procs
## that a caller can choose not to invoke; nothing here executes at
## module-import time.

import std/[httpclient, json, uri, strformat, streams, strutils]
import ../../common/types
import ../log

type
  RouterClient* = ref object
    baseUrl: string
    timeoutMs: int

proc newRouterClient*(host: string, port: int, timeoutMs: int = 5000): RouterClient =
  RouterClient(
    baseUrl: &"http://{host}:{port}",
    timeoutMs: timeoutMs,
  )

proc get(rc: RouterClient, path: string): JsonNode =
  ## Uses a fresh HttpClient per call: a single reused client can end up
  ## holding a socket that llama-server has since closed, causing
  ## intermittent "Connection was closed before full request has been
  ## made" errors.
  let client = newHttpClient(timeout = rc.timeoutMs)
  defer: client.close()
  let resp = client.getContent(rc.baseUrl & path)
  parseJson(resp)

proc postJson*(rc: RouterClient, path: string, body: JsonNode): JsonNode =
  let client = newHttpClient(timeout = rc.timeoutMs)
  defer: client.close()
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  let resp = client.postContent(rc.baseUrl & path, $body)
  parseJson(resp)

proc postJsonStream*(rc: RouterClient, path: string, body: JsonNode,
                      onChunk: proc(chunk: string) {.gcsafe.},
                      isCancelled: proc(): bool {.gcsafe.}): JsonNode =
  ## Streams a chat-completion style POST as Server-Sent Events, invoking
  ## `onChunk` with each incremental assistant text fragment as it arrives.
  ## Uses no fixed request timeout since generation length is unbounded;
  ## `isCancelled` is polled after every SSE line so a caller can abort a
  ## long-running generation (checked between token chunks, so it stays
  ## responsive as long as the model keeps producing output).
  let client = newHttpClient(timeout = -1)
  defer: client.close()
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  let resp = client.request(rc.baseUrl & path, httpMethod = HttpPost, body = $body)
  var fullText = ""
  var lastUsage: JsonNode = nil
  while not resp.bodyStream.atEnd():
    if isCancelled():
      break
    let line = resp.bodyStream.readLine().strip()
    if line.len == 0 or not line.startsWith("data:"):
      continue
    let payload = line[5 .. ^1].strip()
    if payload == "[DONE]":
      break
    let node = parseJson(payload)
    let choices = node{"choices"}
    if choices != nil and choices.kind == JArray and choices.len > 0:
      let delta = choices[0]{"delta"}
      if delta != nil:
        let piece = delta{"content"}.getStr("")
        if piece.len > 0:
          fullText.add(piece)
          onChunk(piece)
    let usage = node{"usage"}
    if usage != nil:
      lastUsage = usage
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
