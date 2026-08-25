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
synth mcp list|auth|logout     MCP servers, and signing in to one
synth mcp enable|disable|debug turn one on or off, or see what discovery finds
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
| `ctrl+v` | paste an image |
| `ctrl+c` | clear the draft, interrupt a turn, then quit |
| `ctrl+z` | suspend to the shell |

`/help` lists the slash commands. `@path` pulls a file into the prompt - an
image comes along as a picture, and a name with spaces is written
`@"Pasted image.png"`.

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

Some settings can be overridden per run by the environment: `SYNTH_PROVIDER`,
`SYNTH_DB`, `SYNTH_DEBUG_LOG`, `OLLAMA_HOST`, `OLLAMA_MODEL`, `OLLAMA_API_KEY`,
`OLLAMA_THINK`, `OPENAI_BASE_URL`, `OPENAI_API_KEY`. Which host-and-key pair
applies depends on the protocol the chosen provider speaks, so having both sets
exported does not hand one server the other's settings.

A debug build keeps all three files in the working directory, so a checkout
never touches installed state.

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
