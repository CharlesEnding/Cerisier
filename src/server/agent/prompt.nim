## Builds the system prompt for the main chat and for sub-agents: tool syntax,
## tool list (external manifests + built-ins), usage guidance, the output
## formatting the UI can render (see formats.nim / web/static/rich.js), and a
## snapshot of the conversation's todo list and files.

import std/strutils
import ../db/database
import ../formats/formats
import ../tools/registry
import ../tools/builtin
import ../files/files

const maxFilesListed = 30

proc buildSystemPrompt*(db: Database, reg: ToolRegistry, convId: int64,
                        forSubAgent = false, allow: seq[string] = @[]): string =
  ## `allow` (sub-agents only) restricts which external tools are listed;
  ## empty means all of them.
  var sections: seq[string] = @[]

  # ---- tools
  var tools = toolCallPreamble()
  tools.add("")
  tools.add(toolDescriptionLines(reg, allow))
  tools.add(builtinPromptLines(forSubAgent))
  sections.add(tools.join("\n"))

  # ---- guidance for the built-ins (main agent only: sub-agents get a task-specific prompt)
  if not forSubAgent:
    sections.add("""## Planning and delegation
For work with three or more steps, first call todo_write with the whole plan (every item "pending"). Call it again whenever an item changes, with exactly one item "in_progress" at a time, until everything is "completed". Always send the complete list.
Use spawn_subagent to keep this conversation's context small: for reading or analysing large files, going through many items one by one (e.g. each image in a folder), research, or any self-contained multi-step job. A sub-agent starts with an empty context and sees only the task and context you give it, so include everything it needs; only its final report comes back to you. Do small jobs yourself.""")

  sections.add("""## Files
Files the user attaches are listed on their message; small text files are pasted in full. Use list_files and read_file for the rest. When the user wants a document, script or data file saved, write it to their computer with write_local_file (runs on their machine; do not paste the content into the chat) and tell them the path. Use write_file only when they ask for a server-side download link; its chip in the chat is the only link that works for server files, so never invent /files/ URLs yourself.""")

  sections.add(formatsPromptFragment(db))

  # ---- current state
  if not forSubAgent:
    let todos = db.listTodos(convId)
    if todos.len > 0:
      var lines = @["## Your current todo list"]
      for t in todos:
        var mark = "[ ]"
        if t.status == "completed":
          mark = "[x]"
        elif t.status == "in_progress":
          mark = "[>]"
        lines.add("- " & mark & " " & t.content)
      sections.add(lines.join("\n"))

  let fileRows = db.listFilesForConversation(convId)
  if fileRows.len > 0:
    var lines = @["## Files in this conversation"]
    for i, f in fileRows:
      if i >= maxFilesListed:
        lines.add("- … and " & $(fileRows.len - maxFilesListed) & " more (use list_files)")
        break
      lines.add("- " & f.name & " (" & humanSize(f.size) & ", " & f.origin & ")")
    sections.add(lines.join("\n"))

  sections.join("\n\n")
