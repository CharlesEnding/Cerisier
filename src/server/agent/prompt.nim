## Builds the system prompt for the main chat and for sub-agents from the
## template in config/system_prompt.md (read on every call, so edits apply to
## the next turn without a rebuild). The template holds the static text; the
## parts that change are filled in here:
##   {{date}} {{os}}   current date, host OS
##   {{system}}        host OS version, CPU, RAM, free disk, installed programs (sysinfo.nim)
##   {{tools}}         tool-call syntax plus external and built-in tool list
##   {{formats}}       what the chat UI can render (see formats.nim / rich.js)
##   {{#main}}...{{/main}}  kept for the main agent, dropped for sub-agents

import std/[strutils, os, times, tables]
import ../db/database
import ../formats/formats
import ../tools/registry
import ../tools/builtin
import ../log
import ./sysinfo

const
  fallbackTemplate = "{{tools}}\n\n{{formats}}"

proc loadTemplate(path: string): string =
  if fileExists(path):
    return readFile(path)
  logWarn("prompt", "template not found: " & path & " (using a minimal one)")
  fallbackTemplate

proc renderTemplate(tpl: string, vars: Table[string, string], forSubAgent: bool): string =
  result = tpl
  const openTag = "{{#main}}"
  const closeTag = "{{/main}}"
  if forSubAgent:
    while true:
      let a = result.find(openTag)
      if a < 0:
        break
      let b = result.find(closeTag, a)
      if b < 0:
        result = result[0 ..< a]
        break
      result = result[0 ..< a] & result[b + closeTag.len .. ^1]
  else:
    result = result.replace(openTag, "").replace(closeTag, "")
  for k, v in vars:
    result = result.replace("{{" & k & "}}", v)
  while "\n\n\n" in result:
    result = result.replace("\n\n\n", "\n\n")
  result = result.strip()

proc buildSystemPrompt*(db: Database, reg: ToolRegistry, convId: int64, promptFile: string,
                        forSubAgent = false, allow: seq[string] = @[]): string =
  ## `allow` (sub-agents only) restricts which external tools are listed;
  ## empty means all of them.
  var vars = initTable[string, string]()
  vars["date"] = now().format("yyyy-MM-dd (dddd)")
  vars["os"] = hostOS
  let wd = db.getConversationWorkingDir(convId)
  vars["working_dir"] = if wd.len > 0: wd else: "(none — tools run in the harness's own directory)"
  vars["system"] = systemInfoText()

  var tools = toolCallPreamble()
  tools.add("")
  tools.add(toolDescriptionLines(reg, allow))
  tools.add(builtinPromptLines(forSubAgent))
  vars["tools"] = tools.join("\n")

  vars["formats"] = formatsPromptFragment(db)

  renderTemplate(loadTemplate(promptFile), vars, forSubAgent)
