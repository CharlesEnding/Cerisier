## Skills: stored prompt templates with {{placeholder}} substitution.
## Kept dependency-free (std/strutils only) — no templating engine needed.

import std/[strutils, tables]
import ../db/database

type
  Skill* = object
    id*: int64
    name*: string
    description*: string
    promptTemplate*: string
    toolAllowlist*: string  ## comma-separated tool names, empty = no restriction

proc render*(skill: Skill, vars: Table[string, string]): string =
  result = skill.promptTemplate
  for key, value in vars:
    result = result.replace("{{" & key & "}}", value)

proc listSkills*(db: Database): seq[Skill] =
  result = @[]
  for (id, name, desc, tmpl, allowlist) in database.listSkills(db):
    result.add(Skill(id: id, name: name, description: desc, promptTemplate: tmpl, toolAllowlist: allowlist))

proc saveSkill*(db: Database, name, description, promptTemplate, toolAllowlist: string) =
  db.upsertSkill(name, description, promptTemplate, toolAllowlist)

proc removeSkill*(db: Database, id: int64) =
  db.deleteSkill(id)
