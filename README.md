# synth

A terminal coding agent, written in Zig. Runs on local or hosted models, with
MCP servers and skills.

The TUI's design is borrowed from [opencode](https://github.com/anomalyco/opencode) -
the layout, the tool cards, the slash picker, the modals.

> Early. It works and it is used daily, but there is no release yet and things
> move.

## Requirements

- Zig 0.16
- A model server: [ollama](https://ollama.com), or anything speaking the OpenAI
  chat API. The model has to support tool calls.

## Build

```sh
zig build              # build synth
zig build run          # build and launch the TUI
zig build test         # the test suite, offline, about two seconds
zig build release      # macOS arm64 and Linux x86-64 into zig-out/<triple>
```

The musl build is static and runs anywhere. There is nothing to install: the
binary is self-contained apart from the model server it talks to.

## First run

Start it in a project:

```sh
synth
```

With no provider connected it opens the provider picker. Pick one, give it a URL
and an API key if it needs one, and the key is stored for next time. `ctrl+p`
reopens that picker later, `ctrl+o` switches models across every connected
provider.

## Commands

```
synth [project]                start the TUI (default)
synth run [--allow] <message>  one headless turn, no TUI
synth session list|show|rm     sessions for this project
synth session search <text>    find text in this project's transcripts
synth mcp list|auth|logout     MCP servers, and signing in to one
synth mcp enable|disable|debug turn one on or off, or see what discovery finds
synth db status|prune|vacuum   what the database holds, and shrinking it
synth skills                   skills on offer, and where they came from
synth models                   models the provider offers
synth prompt                   print the system prompt

  -c, --continue               resume the most recent session here
  -s, --session <id>           resume a session by handle (ses_7k3f9a2b)
  -m, --model <name>           override the model, this run only
      --allow                  run only: approve calls that would prompt
```

`synth run` is the fastest way to answer "does this model actually emit tool
calls" - it drives the real loop and provider and prints each step, denying
anything that would change the project unless `--allow` is given.

## Keys

| key | what it does |
| --- | --- |
| `enter` | send, or steer the turn already running |
| `tab` | cycle mode: build, plan, review |
| `esc` | cancel the turn, reject a pending call, or close what is open |
| `ctrl+o` / `ctrl+p` / `ctrl+s` | model / provider / session |
| `ctrl+r` | rename this session |
| `ctrl+t` | collapse or expand the plan |
| `ctrl+e` | compose the draft in `$EDITOR` |
| `ctrl+v` | paste an image |
| `ctrl+c` | clear the draft, interrupt a turn, then quit |
| `ctrl+z` | suspend to the shell |

`/help` lists the slash commands. `@path` pulls a file into the prompt - an
image comes along as a picture, and a name with spaces is written
`@"Pasted image.png"`.

`ctrl+e` hands the draft to `$VISUAL`, or `$EDITOR`, and takes back what was
saved. The value is run through a shell, so `EDITOR="code -w"` works as long as
it waits.

## Modes

`tab` cycles three. **Build** can read, write and run. **Plan** is read
only and answers with a plan rather than changes. **Review** can read and run
commands - tests, `git diff`, a build - but cannot edit.

Anything that changes the project or runs a command asks first, and a preset of
read-only shell commands skips the prompt.

## Configuration

Three files, split by what they hold.

| file | holds | where |
| --- | --- | --- |
| `config.json` | what you set by hand | `$XDG_CONFIG_HOME/synth/` |
| `auth.json` | API keys, one per provider | `$XDG_DATA_HOME/synth/` |
| `synth.db` | sessions, messages, approvals, the provider and model in use | `$XDG_DATA_HOME/synth/` |

Every `config.json` key is optional. An absent one keeps the built-in default.

| key | type | default | what it does |
| --- | --- | --- | --- |
| `system_prompt` | string | the built-in brief | Replaces the base instructions entirely. |
| `think` | bool | `true` | Ask for reasoning output. Turn off for models that do not support it. |
| `auto_approve_safe_commands` | bool | `true` | Let a preset of read-only shell commands run without a prompt. Off makes every command a question, however harmless. |
| `debug_log` | string | none | Append every request and reply to this file. |
| `max_turn_ms` | number | `1800000` | How long one turn may run. `0` disables it. |
| `max_turn_tokens` | number | `2000000` | Tokens one turn may spend, prompt and completion together. `0` disables it. |
| `skill_paths` | array of strings | `[]` | Extra directories to look for skills in, searched in order. |
| `database_path` | string | `synth.db` beside the other data | Where sessions live. |
| `mcp` | object | none | MCP servers. See below. |
| `hooks` | object | none | Commands run on selected agent lifecycle events. See below. |
| `hook_timeout_ms` | number | `30000` | How long a hook command may run before it is killed. |

```json
{
  "think": true,
  "auto_approve_safe_commands": true,
  "max_turn_tokens": 500000,
  "skill_paths": ["/srv/team/skills"]
}
```

The provider, its host, the model and the theme are **not** in here. They are
set by using the app and kept in the database.

`debug_log` is the first thing to reach for when a model goes quiet: it shows
whether a request was sent at all, and how large it had grown.

Ollama picks the context window a model is loaded with, and what it picks is
usually far below what the model can do. `ollama.num_ctx` is what synth asks
for; leave it out and it asks for the model's advertised maximum, and 0 leaves
the choice to the server. Whether the server can give what was asked for is its
own business: `/api/ps` is the last word on what the runner actually got, and
that is what the sidebar plans against.

Some settings can be overridden per run by the environment: `SYNTH_PROVIDER`,
`SYNTH_DB`, `SYNTH_DEBUG_LOG`, `OLLAMA_HOST`, `OLLAMA_MODEL`, `OLLAMA_API_KEY`,
`OLLAMA_THINK`, `OLLAMA_NUM_CTX`, `OPENAI_BASE_URL`, `OPENAI_API_KEY`, `BRAVE_API_KEY`,
`SYNTH_SEARCH_API_KEY`. `VISUAL` and `EDITOR` decide what `ctrl+e` opens. Which host-and-key pair applies depends on the protocol
the chosen provider speaks, so having both sets exported does not hand one
server the other's settings.

`web_search` needs no key: without one it reads DuckDuckGo's HTML results page.
That works, but DuckDuckGo throttles it after a handful of searches and answers
with a page that has no results on it, which the tool reports as such. A Brave
Search key in `BRAVE_API_KEY` switches it to an API that does not throttle.

A debug build keeps all three files in the working directory, so a checkout
never touches installed state.

`"bell"` decides when a finished turn says so: `unfocused` (the default),
`always`, or `never`. It sends both a desktop notification and BEL, because
neither lands everywhere.

The default needs the terminal to report focus, which synth asks for at startup;
a terminal that does not answer never rings, so use `always` there. Under tmux
both halves need turning on, and neither is the default:

```
set -g focus-events on
set -g allow-passthrough on
```

### Searching

`synth session search <text>`, or `/search <text>` inside the TUI, looks through
every transcript in the project. What was said comes first and tool output
after, since a search is usually after the conversation rather than a file a
tool printed.

The match is plain text, not a query language, so `100%` searches for `100%`.

### Pruning

The database keeps every transcript, and most of its weight is stored tool
output: the full result behind each card, plus the model's reasoning. Left
alone that grows without bound.

A prune runs at startup and reclaims it in two steps, each an age in days since
a session was last touched:

```json
{
  "prune": {
    "shed_after_days": 30,
    "delete_after_days": 0
  }
}
```

`shed_after_days` keeps an old session's transcript but drops the payloads
behind it. The cards still read: what the model was shown is on the tool call
itself, and only the expanded view loses its full text. This is where nearly
all the space goes, so 30 days is the default.

`delete_after_days` removes an old session outright, messages and all. It
defaults to 0, meaning never: losing a transcript is not something to do by
accident. Set it if the machine is short of disk.

Zero switches either half off. `/prune` applies the same policy on demand, and
`synth db` does the same from the shell:

```
synth db status        what it holds, and what a prune would free
synth db prune [days]  shed sessions idle that many days, or use the config
synth db vacuum        hand freed pages back to the filesystem
```

`db status` is a dry run: it says what a prune would take without taking it.
A day count given to `db prune` only ever sheds, so losing a transcript stays
something `config.json` has to ask for.

## MCP

The `mcp` block is the shape every other client uses, so an entry from a
`claude_desktop_config.json` pastes in unchanged:

```json
{
  "mcp": {
    "servers": {
      "files": {
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
      },
      "linear": { "url": "https://mcp.linear.app/mcp" },
      "internal": {
        "url": "https://internal.example/mcp",
        "headers": { "X-Api-Key": "..." }
      }
    }
  }
}
```

A `command` runs a child process; a `url` is a remote server over Streamable
HTTP, signed in with `synth mcp auth <name>` where it needs OAuth. `/mcp` turns
servers on and off without leaving the TUI.

## Hooks

Hooks run commands from the project root at selected lifecycle events. Each
command receives a JSON object on stdin. Tool hooks may set `matcher` to an
exact tool name; an empty or absent matcher matches every tool. A
`UserPromptSubmit` or `PreToolUse` hook blocks the operation by exiting 2, with
its stderr used as the reason. Other exit statuses are advisory. Hook commands
that exceed `hook_timeout_ms` are killed. Hook stderr is kept up to 64 KiB;
anything beyond that is discarded.

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

### Try the logging hook

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

### The other examples

`examples/hooks/` holds four more, each usable as it stands and meant to be
edited into whatever the project actually needs.

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

## Skills

A skill is a directory holding a `SKILL.md`, whose frontmatter names it and says
in one line what it is for:

```markdown
---
name: release
description: how a release is cut here
---

Run the tests, tag, then push.
```

Searched, in order: `.agents/skills` and `.claude/skills` under the project,
whatever `skill_paths` names, then the same pair under `$HOME`. Skills written
for other harnesses work unchanged.

Only the name and description reach the model unasked - it loads the rest when
one applies, or you run it yourself with `/release`. `synth skills` lists what
was found and every directory that was searched.

## Layout

```
src/
  core/       config, auth, sqlite, sessions, @path mentions, search primitives
  provider/   the ollama and OpenAI backends, and what fits in a context window
  agent/      the turn state machine: ask -> approve -> run -> repeat
  tools/      read, list, glob, grep, write, edit, bash, task, ask_user, skill, todo
  tui/        the vxfw widget tree: transcript, composer, pickers, sidebar
packages/
  mcp/        the MCP client, its own package, importing nothing from synth
```

`zig build test` runs the whole tree, `zig build test-mcp` the client alone -
which is also what proves it depends on nothing here.

## Contributing

`zig build test` before opening anything. Tests live next to what they cover.
