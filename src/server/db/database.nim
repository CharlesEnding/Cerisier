## SQLite persistence layer: schema + minimal repository procs for
## conversations, messages, llama sessions, tool calls, skills and formats.
## Kept as plain SQL via db_connector (no ORM) to stay easy to read/extend.

import db_connector/db_sqlite
import std/[options, strutils]

type
  Database* = ref object
    conn*: DbConn

proc open*(path: string): Database =
  result = Database(conn: db_sqlite.open(path, "", "", ""))
  result.conn.exec(sql"PRAGMA foreign_keys = ON;")

proc close*(db: Database) =
  db.conn.close()

proc migrate*(db: Database) =
  db.conn.exec(sql"""
    CREATE TABLE IF NOT EXISTS agent_conversations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL DEFAULT '',
      system_prompt_id INTEGER,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
  """)
  db.conn.exec(sql"""
    CREATE TABLE IF NOT EXISTS agent_messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      conversation_id INTEGER NOT NULL REFERENCES agent_conversations(id),
      parent_id INTEGER REFERENCES agent_messages(id),
      role TEXT NOT NULL,
      content TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
  """)
  db.conn.exec(sql"""
    CREATE TABLE IF NOT EXISTS llama_sessions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      agent_conversation_id INTEGER NOT NULL REFERENCES agent_conversations(id),
      parent_message_id INTEGER REFERENCES agent_messages(id),
      model TEXT NOT NULL DEFAULT '',
      purpose TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'open',
      prompt_tokens INTEGER NOT NULL DEFAULT 0,
      completion_tokens INTEGER NOT NULL DEFAULT 0,
      ctx_size INTEGER NOT NULL DEFAULT 0
    );
  """)
  db.conn.exec(sql"""
    CREATE TABLE IF NOT EXISTS llama_turns (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id INTEGER NOT NULL REFERENCES llama_sessions(id),
      role TEXT NOT NULL,
      content TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
  """)
  db.conn.exec(sql"""
    CREATE TABLE IF NOT EXISTS tool_calls (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      message_id INTEGER NOT NULL REFERENCES agent_messages(id),
      tool_name TEXT NOT NULL,
      location TEXT NOT NULL,
      args_json TEXT NOT NULL DEFAULT '{}',
      status TEXT NOT NULL DEFAULT 'pending_approval',
      result_json TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
  """)
  db.conn.exec(sql"""
    CREATE TABLE IF NOT EXISTS skills (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL UNIQUE,
      description TEXT NOT NULL DEFAULT '',
      prompt_template TEXT NOT NULL DEFAULT '',
      tool_allowlist TEXT NOT NULL DEFAULT ''
    );
  """)
  db.conn.exec(sql"""
    CREATE TABLE IF NOT EXISTS formats (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      tag TEXT NOT NULL UNIQUE,
      css_class TEXT NOT NULL DEFAULT '',
      description TEXT NOT NULL DEFAULT ''
    );
  """)
  db.conn.exec(sql"""
    CREATE TABLE IF NOT EXISTS model_presets (
      id TEXT PRIMARY KEY,
      model_path TEXT NOT NULL DEFAULT '',
      mmproj_path TEXT NOT NULL DEFAULT '',
      ctx_size INTEGER NOT NULL DEFAULT 65536,
      n_gpu_layers TEXT NOT NULL DEFAULT '999',
      chat_template_kwargs TEXT NOT NULL DEFAULT '',
      temperature REAL NOT NULL DEFAULT 1.0,
      top_p REAL NOT NULL DEFAULT 0.95,
      top_k INTEGER NOT NULL DEFAULT 20,
      min_p REAL NOT NULL DEFAULT 0.0,
      presence_penalty REAL NOT NULL DEFAULT 0.0,
      load_on_startup INTEGER NOT NULL DEFAULT 0,
      configured INTEGER NOT NULL DEFAULT 0
    );
  """)

# ---- conversations ----

proc createConversation*(db: Database, title: string): int64 =
  db.conn.insertID(sql"INSERT INTO agent_conversations (title) VALUES (?)", title)

proc listConversations*(db: Database): seq[(int64, string, string)] =
  result = @[]
  for row in db.conn.fastRows(sql"SELECT id, title, created_at FROM agent_conversations ORDER BY id DESC"):
    result.add((parseBiggestInt(row[0]).int64, row[1], row[2]))

proc getConversationTitle*(db: Database, conversationId: int64): string =
  for row in db.conn.fastRows(sql"SELECT title FROM agent_conversations WHERE id = ?", conversationId):
    return row[0]
  ""

proc updateConversationTitle*(db: Database, conversationId: int64, title: string) =
  db.conn.exec(sql"UPDATE agent_conversations SET title = ? WHERE id = ?", title, conversationId)

# ---- messages ----

proc addMessage*(db: Database, conversationId: int64, parentId: Option[int64],
                  role: string, content: string): int64 =
  if parentId.isSome:
    db.conn.insertID(sql"INSERT INTO agent_messages (conversation_id, parent_id, role, content) VALUES (?, ?, ?, ?)",
      conversationId, parentId.get(), role, content)
  else:
    db.conn.insertID(sql"INSERT INTO agent_messages (conversation_id, parent_id, role, content) VALUES (?, NULL, ?, ?)",
      conversationId, role, content)

proc messagesForConversation*(db: Database, conversationId: int64): seq[(int64, string, string, string, string)] =
  ## (id, parent_id or "", role, content, created_at)
  result = @[]
  for row in db.conn.fastRows(sql"""
      SELECT id, COALESCE(parent_id, ''), role, content, created_at
      FROM agent_messages WHERE conversation_id = ? ORDER BY id ASC""", conversationId):
    result.add((parseBiggestInt(row[0]).int64, row[1], row[2], row[3], row[4]))

# ---- llama sessions ----

proc createLlamaSession*(db: Database, conversationId: int64, parentMessageId: Option[int64],
                          model, purpose: string, ctxSize: int): int64 =
  if parentMessageId.isSome:
    db.conn.insertID(sql"""INSERT INTO llama_sessions
        (agent_conversation_id, parent_message_id, model, purpose, ctx_size)
        VALUES (?, ?, ?, ?, ?)""",
      conversationId, parentMessageId.get(), model, purpose, ctxSize)
  else:
    db.conn.insertID(sql"""INSERT INTO llama_sessions
        (agent_conversation_id, parent_message_id, model, purpose, ctx_size)
        VALUES (?, NULL, ?, ?, ?)""",
      conversationId, model, purpose, ctxSize)

proc updateSessionTokens*(db: Database, sessionId: int64, promptTokens, completionTokens: int) =
  db.conn.exec(sql"UPDATE llama_sessions SET prompt_tokens = ?, completion_tokens = ? WHERE id = ?",
    promptTokens, completionTokens, sessionId)

proc closeSession*(db: Database, sessionId: int64, status: string) =
  db.conn.exec(sql"UPDATE llama_sessions SET status = ? WHERE id = ?", status, sessionId)

proc addTurn*(db: Database, sessionId: int64, role, content: string): int64 =
  db.conn.insertID(sql"INSERT INTO llama_turns (session_id, role, content) VALUES (?, ?, ?)",
    sessionId, role, content)

# ---- tool calls ----

proc createToolCall*(db: Database, messageId: int64, toolName, location, argsJson: string): int64 =
  db.conn.insertID(sql"""INSERT INTO tool_calls (message_id, tool_name, location, args_json)
      VALUES (?, ?, ?, ?)""", messageId, toolName, location, argsJson)

proc setToolCallStatus*(db: Database, id: int64, status: string) =
  db.conn.exec(sql"UPDATE tool_calls SET status = ? WHERE id = ?", status, id)

proc setToolCallResult*(db: Database, id: int64, status, resultJson: string) =
  db.conn.exec(sql"UPDATE tool_calls SET status = ?, result_json = ? WHERE id = ?", status, resultJson, id)

proc pendingToolCalls*(db: Database): seq[(int64, int64, string, string, string)] =
  ## (id, message_id, tool_name, location, args_json)
  result = @[]
  for row in db.conn.fastRows(sql"""SELECT id, message_id, tool_name, location, args_json
      FROM tool_calls WHERE status = 'pending_approval' ORDER BY id ASC"""):
    result.add((parseBiggestInt(row[0]).int64, parseBiggestInt(row[1]).int64, row[2], row[3], row[4]))

# ---- skills ----

proc upsertSkill*(db: Database, name, description, promptTemplate, toolAllowlist: string) =
  db.conn.exec(sql"""
    INSERT INTO skills (name, description, prompt_template, tool_allowlist) VALUES (?, ?, ?, ?)
    ON CONFLICT(name) DO UPDATE SET description=excluded.description,
      prompt_template=excluded.prompt_template, tool_allowlist=excluded.tool_allowlist
    """, name, description, promptTemplate, toolAllowlist)

proc listSkills*(db: Database): seq[(int64, string, string, string, string)] =
  result = @[]
  for row in db.conn.fastRows(sql"SELECT id, name, description, prompt_template, tool_allowlist FROM skills ORDER BY name ASC"):
    result.add((parseBiggestInt(row[0]).int64, row[1], row[2], row[3], row[4]))

proc deleteSkill*(db: Database, id: int64) =
  db.conn.exec(sql"DELETE FROM skills WHERE id = ?", id)

# ---- formats ----

proc upsertFormat*(db: Database, tag, cssClass, description: string) =
  db.conn.exec(sql"""
    INSERT INTO formats (tag, css_class, description) VALUES (?, ?, ?)
    ON CONFLICT(tag) DO UPDATE SET css_class=excluded.css_class, description=excluded.description
    """, tag, cssClass, description)

proc listFormats*(db: Database): seq[(int64, string, string, string)] =
  result = @[]
  for row in db.conn.fastRows(sql"SELECT id, tag, css_class, description FROM formats ORDER BY tag ASC"):
    result.add((parseBiggestInt(row[0]).int64, row[1], row[2], row[3]))

proc deleteFormat*(db: Database, id: int64) =
  db.conn.exec(sql"DELETE FROM formats WHERE id = ?", id)

# ---- model presets ----

type
  ModelPresetRow* = tuple
    id: string
    modelPath: string
    mmprojPath: string
    ctxSize: int
    nGpuLayers: string
    chatTemplateKwargs: string
    temperature: float
    topP: float
    topK: int
    minP: float
    presencePenalty: float
    loadOnStartup: bool
    configured: bool

proc upsertModelPreset*(db: Database, p: ModelPresetRow) =
  db.conn.exec(sql"""
    INSERT INTO model_presets
      (id, model_path, mmproj_path, ctx_size, n_gpu_layers, chat_template_kwargs,
       temperature, top_p, top_k, min_p, presence_penalty, load_on_startup, configured)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      model_path=excluded.model_path, mmproj_path=excluded.mmproj_path,
      ctx_size=excluded.ctx_size, n_gpu_layers=excluded.n_gpu_layers,
      chat_template_kwargs=excluded.chat_template_kwargs, temperature=excluded.temperature,
      top_p=excluded.top_p, top_k=excluded.top_k, min_p=excluded.min_p,
      presence_penalty=excluded.presence_penalty, load_on_startup=excluded.load_on_startup,
      configured=excluded.configured
    """, p.id, p.modelPath, p.mmprojPath, p.ctxSize, p.nGpuLayers, p.chatTemplateKwargs,
    p.temperature, p.topP, p.topK, p.minP, p.presencePenalty, ord(p.loadOnStartup), ord(p.configured))

proc rowToModelPreset(row: seq[string]): ModelPresetRow =
  (
    id: row[0],
    modelPath: row[1],
    mmprojPath: row[2],
    ctxSize: parseInt(row[3]),
    nGpuLayers: row[4],
    chatTemplateKwargs: row[5],
    temperature: parseFloat(row[6]),
    topP: parseFloat(row[7]),
    topK: parseInt(row[8]),
    minP: parseFloat(row[9]),
    presencePenalty: parseFloat(row[10]),
    loadOnStartup: row[11] != "0",
    configured: row[12] != "0",
  )

const modelPresetCols = """id, model_path, mmproj_path, ctx_size, n_gpu_layers, chat_template_kwargs,
      temperature, top_p, top_k, min_p, presence_penalty, load_on_startup, configured"""

proc listModelPresets*(db: Database): seq[ModelPresetRow] =
  result = @[]
  for row in db.conn.fastRows(sql("SELECT " & modelPresetCols & " FROM model_presets ORDER BY id ASC")):
    result.add(rowToModelPreset(row))

proc getModelPreset*(db: Database, id: string): Option[ModelPresetRow] =
  for row in db.conn.fastRows(sql("SELECT " & modelPresetCols & " FROM model_presets WHERE id = ?"), id):
    return some(rowToModelPreset(row))
  none(ModelPresetRow)

proc countModelPresets*(db: Database): int64 =
  for row in db.conn.fastRows(sql"SELECT COUNT(*) FROM model_presets"):
    return parseBiggestInt(row[0])
  0

proc deleteModelPreset*(db: Database, id: string) =
  db.conn.exec(sql"DELETE FROM model_presets WHERE id = ?", id)

