# Adding a new tool

A tool is two files that live together in this repo:

1. A **manifest** — `tools/<name>.tool.json` — a small JSON description the harness reads to expose the tool to the model (name, schema, approval policy).
2. An **implementation** — `tools/scripts/<name>.py` — a Python script that does the actual work and prints a JSON result.

The tool registry scans `tools/` for `*.tool.json` at startup and, for each one, registers the manifest's `name` as the callable tool. So adding files is the whole act of adding a tool. The name of the tool shall start with a verb (e.g: list_processes not process_list).

## How a tool runs

For a `kind: "python"` tool the harness does, effectively:

```
python3 <entrypoint> '<argsJson>'
```

where `<argsJson>` is the JSON object the model passed as the tool's arguments. The script must print **exactly one JSON line** describing the result and nothing else on stdout:

```json
{"ok": true,  "data": { ... }}
{"ok": false, "error": "human-readable reason"}
```

The `data` object is validated against the manifest's `output_schema`; on a mismatch the call is treated as failed. The script should therefore read args from `sys.argv[1]`, never assume they exist, and never print debug output to stdout.

```python
#!/usr/bin/env python3
import json, sys

def main():
    try:
        args = json.loads(sys.argv[1])
    except (IndexError, json.JSONDecodeError) as e:
        print(json.dumps({"ok": False, "error": f"invalid arguments: {e}"}))
        return

    # ... do the work ...

    print(json.dumps({"ok": True, "data": {"result": "..."}}))

if __name__ == "__main__":
    main()
```

## The manifest

```json
{
  "name": "check_installed",
  "description": "Check whether a program/command is installed on PATH and report its path.",
  "kind": "python",
  "entrypoint": "tools/scripts/check_installed.py",
  "input_schema": {
    "type": "object",
    "required": ["name"],
    "properties": {
      "name": {"type": "string", "description": "Program or command name to look up."}
    }
  },
  "output_schema": {
    "type": "object",
    "required": ["name", "found", "path"],
    "properties": {
      "name": {"type": "string"},
      "found": {"type": "boolean"},
      "path": {"type": "string"}
    }
  },
  "timeout_ms": 5000,
  "permission": "auto"
}
```

| Field | Required | Notes |
|---|---|---|
| `name` | yes | The callable name; must match the `<name>` part of the file. |
| `description` | yes | What the tool does — the model decides to use it from this. |
| `kind` | yes | Currently `"python"`. |
| `entrypoint` | yes | Path **relative to the project root**, e.g. `tools/scripts/foo.py`. The registry resolves it from the parent of `tools/`, so write it exactly like this. |
| `input_schema` | yes | JSON Schema object. `required` lists mandatory args; give every arg a `description`. |
| `output_schema` | yes | Shape of the `data` object. The harness checks declared `type`s and `required` keys; object/array shapes that omit `properties`/`items` are not deep-validated, and `required` itself is optional. Keep it faithful to what you actually return. |
| `timeout_ms` | no | Hard kill timeout; small for quick tools (`5000`), larger for network/heavy work. |
| `permission` | no | `"auto"`, `"ask"` (default), or `"auto_workdir"` — see the Permission section. |
| `path_args` | no | Input arg names that are filesystem paths (e.g. `["input_path", "output_path"]`). Gates the working-dir scope for `auto_workdir`; shapes the prompt for `ask`; ignored by `auto`. |

## Permission: `auto`, `ask`, and `auto_workdir`

This is the approval gate, and the main reason a dedicated tool exists instead of the approval-gated `run_command`.

- **`"ask"` (default)** — the harness shows the call and waits for the user to approve before running it. Use for anything that writes, deletes, installs, or is otherwise hard to undo: `write_local_file`, `run_command`, `run_python`, the image/PDF writers, `screenshot`, `read_webpage`.
- **`"auto"`** — the harness validates the args against `input_schema` and runs immediately, with no chat prompt. Use for **read-only, side-effect-free** operations: `check_installed`, `machine_config`, `list_dir`, `render_tree`, `git_read`, `list_processes`, `list_python_packages`, the `search_*` tools.
- **`"auto_workdir"`** — auto-runs when the paths in `path_args` resolve **inside the working directory**; anything outside falls back to the approval prompt. This is how a tool that reads user files (`read_local_file`) stays frictionless for normal work without granting blanket file access. It is the one permission where `path_args` actually gates behaviour.

Choosing the value: read-only and touches nothing user-owned → `auto`; reads arbitrary files the user may not own → `auto_workdir`; writes/installs/irreversible → `ask`.

`path_args` is ignored by `auto` tools but is still often listed for consistency (the `search_*` tools carry `path_args: []`). It only has effect for `ask` (shaping the prompt) and `auto_workdir` (deciding scope).

## Safety: no shell, no injection

Never build a command as a string and hand it to the shell. Pass arguments as a list so user-supplied values are never interpreted by a shell:

```python
# GOOD — args are data, never parsed by a shell.
subprocess.run(["git", "status", "-s", repo], capture_output=True, text=True)

# BAD — the repo string is shell-interpreted.
subprocess.run(f"git status -s {repo}", shell=True)
```

A read-only tool that only invokes commands with list args and filters the result is the textbook candidate for `permission: "auto"`.

## Worked example: `list_processes`

The reasoning that led to this tool is a good template for the whole process.

**Goal.** Give the model `ps aux | grep <pattern>` *without* the `run_command` approval step.

**Decisions.**
- *No shell.* Run `ps` with list args (`["ps", "-A", "-ww", "-o", ...]`); the pattern is matched in Python, so there is no injection surface — the same approach as `git_read`.
- *Grep in Python, not a real grep.* Because the filtering is done in the script there is no separate `grep` process, so (unlike `ps aux | grep foo`) the filter never matches its own line.
- *Match the whole rendered line.* A grep sees the entire `pid user %cpu %mem stat command` string, so the pattern is matched against that whole line — it can hit a user, a pid, or the command.
- *Stable parsing.* Pick `ps` columns that are guaranteed to be single, space-free tokens and put `command` (the only field that can contain spaces) last, then `line.split(maxsplit=5)` and treat the remainder as the command. Avoid columns like `start`, which can contain a space and break naive splitting.
- *Full command width.* `-ww` (procps: two `-w` flags = unlimited width) so long command lines aren't truncated and the grep still matches.
- *No path_args, `permission: "auto"`.* It reads and filters; nothing is written.

The resulting manifest declares the same input options as grep — `pattern`, `ignore_case`, `fixed`, `invert`, `max_matches` — and `permission: "auto"`. The script prints `{"ok": true, "data": {"pattern", "processes", "count", "total_matched", "truncated"}}`, and `output_schema` matches it.

## Common output conventions

Following the existing tools makes the `output_schema` easy to write and keeps results predictable:

- **Listing / searching tools** end with `count` (number returned) and `truncated` (more exist than were returned): `list_dir`, `render_tree`, `list_processes`, `list_python_packages`, `search_files`.
- **The `search_*` family** (web, github, steam, youtube) share a card shape — `required: ["type", "source", "query", "results", "text"]`, with `results` an array of objects. These are the only tools whose results the UI renders as embed cards via a `[[search:…]]` directive line.
- **File-writing tools** report what changed on disk: `bytes_written` (`write_local_file`, `write_tmp_file`) or an `output_path` plus size/page counts (`pdf_*`, image tools).
- A `path` echoing the input is a common `required` field for path-based tools.

## Testing a new tool

There is no dedicated runner for a script with arguments, so invoke it directly with the same contract the harness uses:

```bash
python3 tools/scripts/<name>.py '{"pattern": "python"}'
```

Check three things:
1. The script prints a single `{"ok": true, "data": ...}` line — nothing else on stdout.
2. The `data` object matches `output_schema` (types and required keys).
3. A bad-input call (`'{}'` or a malformed pattern) returns `{"ok": false, "error": ...}`, not a crash or empty output.

## When a new tool becomes available

The registry reads the `tools/` directory at startup. After adding the manifest and script, the tool is available on the next start (or a registry reload). There is no other registration step.

## Checklist

- [ ] `tools/<name>.tool.json` written; `name` matches the filename and the manifest `name`.
- [ ] `entrypoint` is `tools/scripts/<name>.py` (relative to the project root).
- [ ] `input_schema` / `output_schema` describe the real args and the real `data` shape.
- [ ] `description` is specific — the model picks the tool from it.
- [ ] Script reads `sys.argv[1]`, handles missing/bad args, prints exactly one `{"ok": …}` line.
- [ ] Any external command is invoked with a **list of args**, never `shell=True`.
- [ ] `permission` chosen right: `auto` only if read-only and side-effect-free; `auto_workdir` if it reads user files by path; `ask` if it writes or is hard to undo.
- [ ] Tested from the command line with a valid and an invalid call.
