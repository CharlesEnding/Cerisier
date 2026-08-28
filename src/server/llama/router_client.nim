## Typed HTTP client wrapping the llama-server router-mode API.
## Compile-only verification project: no live router is expected to be
## reachable on this dev machine, so all calls are behind explicit procs
## that a caller can choose not to invoke; nothing here executes at
## module-import time.

import std/[httpclient, json, uri, strformat]
import ../../common/types

type
  RouterClient* = ref object
    baseUrl: string
    client: HttpClient
    timeoutMs: int

proc newRouterClient*(host: string, port: int, timeoutMs: int = 5000): RouterClient =
  RouterClient(
    baseUrl: &"http://{host}:{port}",
    client: newHttpClient(timeout = timeoutMs),
    timeoutMs: timeoutMs,
  )

proc get(rc: RouterClient, path: string): JsonNode =
  let resp = rc.client.getContent(rc.baseUrl & path)
  parseJson(resp)

proc postJson*(rc: RouterClient, path: string, body: JsonNode): JsonNode =
  rc.client.headers = newHttpHeaders({"Content-Type": "application/json"})
  let resp = rc.client.postContent(rc.baseUrl & path, $body)
  parseJson(resp)

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

proc loadModel*(rc: RouterClient, modelId: string): bool =
  let body = %*{"model": modelId}
  let resp = rc.postJson("/models/load", body)
  resp{"success"}.getBool(false)

proc unloadModel*(rc: RouterClient, modelId: string): bool =
  let body = %*{"model": modelId}
  let resp = rc.postJson("/models/unload", body)
  resp{"success"}.getBool(false)

proc props*(rc: RouterClient, modelId: string = ""): JsonNode =
  let path = if modelId.len > 0: "/props?model=" & encodeUrl(modelId) else: "/props"
  rc.get(path)
