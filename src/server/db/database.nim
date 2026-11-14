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

proc columnExists(db: Database, table, column: string): bool =
  for row in db.conn.fastRows(sql("PRAGMA table_info(" & table & ")")):
    if row[1] == column:
      return true
  false

proc ensureColumn(db: Database, table, column, ddl: string) =
  ## `CREATE TABLE IF NOT EXISTS` never adds columns to a table that already
  ## exists, so columns introduced after a database was first created are
  ## added here (idempotent).
  if not db.columnExists(table, column):
    db.conn.exec(sql("ALTER TABLE " & table & " ADD COLUMN " & column & " " & ddl))

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
    CREATE TABLE IF NOT EXISTS files (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      conversation_id INTEGER NOT NULL REFERENCES agent_conversations(id),
      message_id INTEGER REFERENCES agent_messages(id),
      name TEXT NOT NULL,
      stored_name TEXT NOT NULL,
      mime TEXT NOT NULL DEFAULT '',
      size INTEGER NOT NULL DEFAULT 0,
      origin TEXT NOT NULL DEFAULT 'upload',
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
  """)
  db.conn.exec(sql"""
    CREATE TABLE IF NOT EXISTS todos (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      conversation_id INTEGER NOT NULL REFERENCES agent_conversations(id),
      position INTEGER NOT NULL DEFAULT 0,
      content TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'pending'
    );
  """)
  ## Column added after the table already exists in older databases, so use
  ## the idempotent ALTER path rather than the CREATE TABLE above.
  db.ensureColumn("agent_conversations", "working_dir", "TEXT NOT NULL DEFAULT ''")
  db.ensureColumn("agent_conversations", "reasoning_effort", "TEXT NOT NULL DEFAULT ''")

# ---- conversations ----

proc createConversation*(db: Database, title: string): int64 =
  db.conn.insertID(sql"INSERT INTO agent_conversations (title) VALUES (?)", title)

proc listConversations*(db: Database): seq[(int64, string, string)] =
  result = @[]
  for row in db.conn.fastRows(sql"SELECT id, title, created_at FROM agent_conversations ORDER BY id DESC"):
    result.add((parseBiggestInt(row[0]).int64, row[1], row[2]))

proc deleteConversation*(db: Database, conversationId: int64) =
  ## Children first: foreign keys are enforced.
  db.conn.exec(sql"BEGIN")
  try:
    db.conn.exec(sql"""DELETE FROM tool_calls WHERE message_id IN
        (SELECT id FROM agent_messages WHERE conversation_id = ?)""", conversationId)
    db.conn.exec(sql"""DELETE FROM llama_turns WHERE session_id IN
        (SELECT id FROM llama_sessions WHERE agent_conversation_id = ?)""", conversationId)
    db.conn.exec(sql"DELETE FROM llama_sessions WHERE agent_conversation_id = ?", conversationId)
    db.conn.exec(sql"DELETE FROM files WHERE conversation_id = ?", conversationId)
    db.conn.exec(sql"DELETE FROM todos WHERE conversation_id = ?", conversationId)
    db.conn.exec(sql"DELETE FROM agent_messages WHERE conversation_id = ?", conversationId)
    db.conn.exec(sql"DELETE FROM agent_conversations WHERE id = ?", conversationId)
    db.conn.exec(sql"COMMIT")
  except CatchableError:
    db.conn.exec(sql"ROLLBACK")
    raise

proc getConversationTitle*(db: Database, conversationId: int64): string =
  for row in db.conn.fastRows(sql"SELECT title FROM agent_conversations WHERE id = ?", conversationId):
    return row[0]
  ""

proc updateConversationTitle*(db: Database, conversationId: int64, title: string) =
  db.conn.exec(sql"UPDATE agent_conversations SET title = ? WHERE id = ?", title, conversationId)

proc getConversationWorkingDir*(db: Database, conversationId: int64): string =
  ## The conversation's configured working directory, or "" when unset. The
  ## harness reads this to (1) decide the auto_workdir gate and (2) set the
  ## subprocess cwd / CERISIER_WORKING_DIR so the tool sees the real directory
  ## rather than something the model could lie about.
  for row in db.conn.fastRows(sql"SELECT COALESCE(working_dir, '') FROM agent_conversations WHERE id = ?", conversationId):
    return row[0]
  ""

proc setConversationWorkingDir*(db: Database, conversationId: int64, workingDir: string) =
  db.conn.exec(sql"UPDATE agent_conversations SET working_dir = ? WHERE id = ?", workingDir, conversationId)

proc getConversationEffort*(db: Database, conversationId: int64): string =
  ## Thinking effort chosen for this conversation, or "" to use the model's default.
  for row in db.conn.fastRows(sql"SELECT COALESCE(reasoning_effort, '') FROM agent_conversations WHERE id = ?", conversationId):
    return row[0]
  ""

proc setConversationEffort*(db: Database, conversationId: int64, effort: string) =
  db.conn.exec(sql"UPDATE agent_conversations SET reasoning_effort = ? WHERE id = ?", effort, conversationId)

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

proc createToolCall*(db: Database, messageId: int64, toolName, argsJson: string): int64 =
  ## `location` is a legacy NOT NULL column; every call runs locally now.
  db.conn.insertID(sql"""INSERT INTO tool_calls (message_id, tool_name, location, args_json)
      VALUES (?, ?, 'local', ?)""", messageId, toolName, argsJson)

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

proc getToolCall*(db: Database, id: int64): tuple[status, resultJson, toolName, argsJson: string] =
  for row in db.conn.fastRows(sql"""SELECT status, COALESCE(result_json, ''), tool_name, args_json
      FROM tool_calls WHERE id = ?""", id):
    return (row[0], row[1], row[2], row[3])
  ("", "", "", "")

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

# ---- files (uploads from the user, files generated by the agent) ----

type
  FileRow* = tuple
    id: int64
    conversationId: int64
    messageId: int64      ## 0 when the file is not attached to a message
    name: string          ## sanitized display name
    storedName: string    ## unique on-disk name inside the conversation's directory
    mime: string
    size: int64
    origin: string        ## "upload" | "generated"

const fileCols = "id, conversation_id, COALESCE(message_id, 0), name, stored_name, mime, size, origin"

proc rowToFile(row: seq[string]): FileRow =
  (
    id: parseBiggestInt(row[0]).int64,
    conversationId: parseBiggestInt(row[1]).int64,
    messageId: parseBiggestInt(row[2]).int64,
    name: row[3],
    storedName: row[4],
    mime: row[5],
    size: parseBiggestInt(row[6]).int64,
    origin: row[7],
  )

proc createFile*(db: Database, conversationId: int64, name, storedName, mime: string,
                 size: int64, origin: string): int64 =
  db.conn.insertID(sql"""INSERT INTO files (conversation_id, name, stored_name, mime, size, origin)
      VALUES (?, ?, ?, ?, ?, ?)""", conversationId, name, storedName, mime, size, origin)

proc updateFileSize*(db: Database, id: int64, size: int64) =
  db.conn.exec(sql"UPDATE files SET size = ? WHERE id = ?", size, id)

proc attachFileToMessage*(db: Database, fileId, messageId, conversationId: int64) =
  ## Only attaches a still-unattached file that belongs to this conversation,
  ## so a client can't hijack another conversation's files by guessing ids.
  db.conn.exec(sql"""UPDATE files SET message_id = ?
      WHERE id = ? AND conversation_id = ? AND message_id IS NULL""", messageId, fileId, conversationId)

proc getFile*(db: Database, id: int64): Option[FileRow] =
  for row in db.conn.fastRows(sql("SELECT " & fileCols & " FROM files WHERE id = ?"), id):
    return some(rowToFile(row))
  none(FileRow)

proc listFilesForMessage*(db: Database, messageId: int64): seq[FileRow] =
  result = @[]
  for row in db.conn.fastRows(sql("SELECT " & fileCols & " FROM files WHERE message_id = ? ORDER BY id ASC"), messageId):
    result.add(rowToFile(row))

proc listFilesForConversation*(db: Database, conversationId: int64): seq[FileRow] =
  result = @[]
  for row in db.conn.fastRows(sql("SELECT " & fileCols & " FROM files WHERE conversation_id = ? ORDER BY id ASC"), conversationId):
    result.add(rowToFile(row))

proc findFileByName*(db: Database, conversationId: int64, name: string): Option[FileRow] =
  ## Most recent file with this display name in the conversation.
  for row in db.conn.fastRows(sql("SELECT " & fileCols & " FROM files WHERE conversation_id = ? AND name = ? ORDER BY id DESC LIMIT 1"),
                              conversationId, name):
    return some(rowToFile(row))
  none(FileRow)

# ---- todos (agent-maintained checklist shown above the chat input) ----

type
  TodoRow* = tuple
    content: string
    status: string        ## "pending" | "in_progress" | "completed"

proc replaceTodos*(db: Database, conversationId: int64, items: seq[TodoRow]) =
  ## The agent always sends the complete list, so this swaps it atomically.
  db.conn.exec(sql"BEGIN")
  try:
    db.conn.exec(sql"DELETE FROM todos WHERE conversation_id = ?", conversationId)
    for i, it in items:
      db.conn.exec(sql"INSERT INTO todos (conversation_id, position, content, status) VALUES (?, ?, ?, ?)",
        conversationId, i, it.content, it.status)
    db.conn.exec(sql"COMMIT")
  except CatchableError:
    db.conn.exec(sql"ROLLBACK")
    raise

proc listTodos*(db: Database, conversationId: int64): seq[TodoRow] =
  result = @[]
  for row in db.conn.fastRows(sql"SELECT content, status FROM todos WHERE conversation_id = ? ORDER BY position ASC, id ASC", conversationId):
    result.add((content: row[0], status: row[1]))

proc clearTodos*(db: Database, conversationId: int64) =
  db.conn.exec(sql"DELETE FROM todos WHERE conversation_id = ?", conversationId)

