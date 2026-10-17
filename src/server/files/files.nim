## Files as input and output for the agent.
##
## * Uploads: the user attaches files in the chat; they are stored under
##   `<dataDir>/files/<conversationId>/` and described to the model (small text
##   files are inlined, images are sent to vision-capable models, everything
##   else is reachable through the `read_file` built-in tool).
## * Generated files: the model creates files with the `write_file` built-in;
##   they appear in the chat as download chips.
##
## Everything lives inside one directory per conversation and is addressed by
## display name or database id — a model/user supplied path is never used to
## touch the file system, so there is no traversal surface.

import std/[os, strutils, options, oids, base64, unicode, mimetypes, json]
import ../db/database

const
  maxUploadBytes* = 64 * 1024 * 1024
  maxInlineTextBytes* = 12_000    ## attachments up to this size are pasted into the prompt
  maxInlineTotalBytes* = 32_000   ## ...up to this much per message
  maxImageBytes* = 8 * 1024 * 1024
  defaultReadBytes* = 16_000
  maxReadBytes* = 64_000

  ## Served with a `.txt` suffix on disk so the browser shows them as plain
  ## text instead of executing them on our origin.
  unsafeServeExts = [".html", ".htm", ".xhtml", ".svg", ".xml", ".js", ".mjs"]

proc filesRoot*(dataDir: string): string =
  dataDir / "files"

proc convDir*(dataDir: string, conversationId: int64): string =
  filesRoot(dataDir) / $conversationId

proc humanSize*(n: int64): string =
  if n < 1024:
    $n & " B"
  elif n < 1024 * 1024:
    formatFloat(n.float / 1024.0, ffDecimal, 1) & " KB"
  else:
    formatFloat(n.float / 1048576.0, ffDecimal, 1) & " MB"

proc trimToUtf8*(s: string): string =
  ## Drops a partial UTF-8 sequence at either end (after slicing bytes).
  var a = 0
  var b = s.len
  while a < b and (ord(s[a]) and 0xC0) == 0x80:
    inc a
  var j = b - 1
  var back = 0
  while j >= a and (ord(s[j]) and 0xC0) == 0x80 and back < 3:
    dec j
    inc back
  if j >= a:
    let c = ord(s[j])
    let need = if c >= 0xF0: 4 elif c >= 0xE0: 3 elif c >= 0xC0: 2 else: 1
    if need > b - j:
      b = j
  s[a ..< b]

proc sanitizeFileName*(name: string): string =
  ## Keeps letters, digits, a few safe punctuation characters and UTF-8 bytes;
  ## everything else (path separators included) becomes `_`.
  let base = extractFilename(name.replace('\\', '/'))
  var cleaned = ""
  for c in base:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '.', '_', '-', ' ', '(', ')'} or ord(c) >= 128:
      cleaned.add(c)
    else:
      cleaned.add('_')
  cleaned = cleaned.strip(chars = {' ', '.'})
  if cleaned.len > 120:
    let (_, nm, ext) = splitFile(cleaned)
    cleaned = trimToUtf8(nm[0 ..< min(nm.len, max(1, 120 - ext.len))]) & ext
  if cleaned.len == 0:
    cleaned = "file"
  cleaned

proc storedNameFor*(safeName: string): string =
  result = $genOid() & "_" & safeName
  if splitFile(safeName).ext.toLowerAscii() in unsafeServeExts:
    result.add(".txt")

proc guessMime*(name, given: string): string =
  let g = given.strip()
  if g.len > 0 and g != "application/octet-stream":
    return g
  let ext = splitFile(name).ext.strip(chars = {'.'})
  if ext.len == 0:
    return "application/octet-stream"
  let db = newMimetypes()
  db.getMimetype(ext, "application/octet-stream")

proc isVisionImage*(mime: string): bool =
  mime in ["image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp"]

proc looksLikeText*(sample: string): bool =
  if sample.len == 0:
    return true
  for c in sample:
    if c == '\0':
      return false
  validateUtf8(trimToUtf8(sample)) == -1

proc readFileSlice*(path: string, offset, length: int): tuple[content: string, total: int64, truncated: bool] =
  ## Reads up to `length` bytes starting at byte `offset`, trimmed to valid UTF-8.
  let total = getFileSize(path)
  if length <= 0 or offset.int64 >= total:
    return ("", total, false)
  var f = open(path, fmRead)
  defer: f.close()
  f.setFilePos(offset.int64)
  var buf = newString(length)
  let n = f.readBuffer(addr buf[0], length)
  buf.setLen(n)
  (trimToUtf8(buf), total, offset.int64 + n.int64 < total)

proc fileToJson*(f: FileRow): JsonNode =
  %*{
    "id": f.id,
    "name": f.name,
    "size": f.size,
    "mime": f.mime,
    "url": "/files/" & $f.id,
    "isImage": f.mime.startsWith("image/"),
  }

# ---------------------------------------------------------------- saving

proc saveFileBytes*(db: Database, dataDir: string, conversationId: int64,
                    name, mime, origin, data: string): FileRow =
  let safe = sanitizeFileName(name)
  let stored = storedNameFor(safe)
  createDir(convDir(dataDir, conversationId))
  writeFile(convDir(dataDir, conversationId) / stored, data)
  let id = db.createFile(conversationId, safe, stored, guessMime(safe, mime), data.len.int64, origin)
  db.getFile(id).get()

proc writeGeneratedFile*(db: Database, dataDir: string, conversationId: int64,
                         name, data: string): FileRow =
  ## Writing the same name twice updates the earlier *generated* file in place
  ## (uploads are never overwritten by the model).
  let safe = sanitizeFileName(name)
  let existing = db.findFileByName(conversationId, safe)
  if existing.isSome and existing.get().origin == "generated":
    let f = existing.get()
    writeFile(convDir(dataDir, conversationId) / f.storedName, data)
    db.updateFileSize(f.id, data.len.int64)
    return db.getFile(f.id).get()
  saveFileBytes(db, dataDir, conversationId, safe, "", "generated", data)

# ---------------------------------------------------------------- describing attachments to the model

proc describeAttachments*(db: Database, dataDir: string, messageId: int64,
                          visionOk: bool): tuple[note: string, images: seq[string]] =
  ## Text appended to a user message that has attachments, plus data: URIs for
  ## images (only when the current model can actually see images).
  result.note = ""
  result.images = @[]
  let attached = db.listFilesForMessage(messageId)
  if attached.len == 0:
    return
  var listing = "\n\n[Attached files]\n"
  var inlined = ""
  var budget = maxInlineTotalBytes
  for f in attached:
    let path = convDir(dataDir, f.conversationId) / f.storedName
    let head = "- " & f.name & " (" & f.mime & ", " & humanSize(f.size) & ")"
    if not fileExists(path):
      listing.add(head & " — file is missing on the server\n")
      continue
    if isVisionImage(f.mime):
      if visionOk and f.size <= maxImageBytes:
        result.images.add("data:" & f.mime & ";base64," & encode(readFile(path)))
        listing.add(head & " — attached as an image\n")
      else:
        listing.add(head & " — image; not shown (the current model cannot view images, or it is too large)\n")
      continue
    let sample = readFileSlice(path, 0, 4096).content
    if not looksLikeText(sample):
      listing.add(head & " — binary file; cannot be read as text. Server path: " & path & "\n")
    elif f.size <= maxInlineTextBytes and f.size <= budget:
      budget -= f.size.int
      listing.add(head & " — contents below\n")
      inlined.add("\n--- " & f.name & " ---\n" & readFile(path) & "\n--- end of " & f.name & " ---\n")
    else:
      listing.add(head & " — too large to paste here; read it in pieces with read_file {\"name\": \"" &
        f.name & "\", \"offset\": 0}. Server path: " & path & "\n")
  result.note = listing & inlined
