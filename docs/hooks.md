# Hooks

Hooks run commands from the project root at selected lifecycle events. Each
command receives a JSON object on stdin. Tool hooks may set `matcher` to an
exact tool name; an empty or absent matcher matches every tool. A
`UserPromptSubmit` or `PreToolUse` hook blocks the operation by exiting 2, with
its stderr used as the reason. Other exit statuses are advisory. Hook commands
that exceed `hook_timeout_ms` (a [config](configuration.md) key) are killed.
Hook stderr is kept up to 64 KiB; anything beyond that is discarded.

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "command": "./scripts/log-prompt.sh" }
    ],
    "PreToolUse": [
      { "matcher": "bash", "command": "./scripts/check-command.sh" }
    ],
    "PostToolUse": [
      { "matcher": "edit", "command": "zig fmt src" }
    ]
  }
}
```

Input includes `hook_event_name` and `cwd`, plus `prompt` for prompt hooks or
`tool_name`, `tool_input`, and (afterward) `tool_response` for tool hooks.
Tool hooks run once per tool call, and synth may run up to eight calls at once.
A matcher-less `PreToolUse` and `PostToolUse` pair can therefore start 16 hook
processes for one batch, so use `matcher` when a hook only applies to some tools.

## Examples

The repository includes `examples/hooks/log-event.sh`, a dependency-free hook
that appends the timestamp and input JSON for each event to
`.synth-hooks.log`. Add this block to the checkout's `config.json`:

```json
{
  "think": true,
  "hooks": {
    "UserPromptSubmit": [
      { "command": "./examples/hooks/log-event.sh" }
    ],
    "PreToolUse": [
      { "command": "./examples/hooks/log-event.sh" }
    ],
    "PostToolUse": [
      { "command": "./examples/hooks/log-event.sh" }
    ]
  }
}
```

Start synth and submit a prompt, then inspect the log from another terminal:

```sh
tail -f .synth-hooks.log
```

`UserPromptSubmit` appears for every prompt. The pre- and post-tool entries
appear when the model calls a tool. The log is covered by the repository's
`*.log` ignore rule.

`examples/hooks/` holds five, each usable as it stands and meant to be edited
into whatever the project actually needs.

| Hook | Event | Needs | What it does |
| --- | --- | --- | --- |
| `deny-command.sh` | `PreToolUse`, matcher `bash` | `jq` | Refuses force-pushes, `reset --hard`, `terraform apply`, cluster deletes, package publishes, and recursive deletes above the checkout. |
| `protect-paths.sh` | `PreToolUse`, matchers `edit` and `write` | `jq` | Refuses `.env`, lockfiles, CI config, applied migrations and private keys. |
| `format-after-edit.sh` | `PostToolUse`, matchers `edit` and `write` | `zig` | Runs `zig fmt` so the model does not spend turns on whitespace. |
| `block-secrets.sh` | `UserPromptSubmit` | none | Refuses a prompt carrying what looks like a live credential. |

`deny-command.sh` and `protect-paths.sh` decide *never*, which is the part
`auto_approve_safe_commands` cannot express: that setting chooses between
running a command and asking about it, and a hook is what removes the option.

`block-secrets.sh` is the counterpart to the redaction synth already applies to
tool output: that covers a key on the way out of a tool, this covers one pasted
in on the way to the model.

Both `jq` hooks exit 0 when `jq` is missing, so a checkout without it allows
rather than blocks. Decide whether that is the tradeoff you want before relying
on either as policy.

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "command": "./examples/hooks/block-secrets.sh" }
    ],
    "PreToolUse": [
      { "matcher": "bash", "command": "./examples/hooks/deny-command.sh" },
      { "matcher": "edit", "command": "./examples/hooks/protect-paths.sh" },
      { "matcher": "write", "command": "./examples/hooks/protect-paths.sh" }
    ],
    "PostToolUse": [
      { "matcher": "edit", "command": "./examples/hooks/format-after-edit.sh" },
      { "matcher": "write", "command": "./examples/hooks/format-after-edit.sh" }
    ]
  }
}
```
