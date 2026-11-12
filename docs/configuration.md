# Configuration

## Files

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
| `approvals` | string | `"ask"` | Who decides a call that would otherwise ask: `ask` puts it to you, `auto` has the session's model judge it (see [Auto approvals](usage.md#auto-approvals)), `all` runs everything, paths outside the project included - for a machine set aside for the agent. `PreToolUse` hooks still run under each. Turns still stop at their limits; to let one run until the work is done, set the three below to `0` as well. |
| `debug_log` | string | none | Append every request and reply to this file. |
| `max_turn_ms` | number | `1800000` | How long one turn may run. `0` disables it. |
| `max_turn_tokens` | number | `2000000` | Tokens one turn may spend, prompt and completion together. `0` disables it. |
| `max_stall_ms` | number | `120000` | How long the provider may send nothing before the turn is given up on. `0` disables it. With all three of these at `0`, the agent's cap on model calls per turn is lifted too. |
| `skill_paths` | array of strings | `[]` | Extra directories to look for skills in, searched in order. |
| `database_path` | string | `synth.db` beside the other data | Where sessions live. |
| `mcp` | object | none | MCP servers. See [MCP](mcp.md). |
| `hooks` | object | none | Commands run on selected agent lifecycle events. See [Hooks](hooks.md). |
| `hook_timeout_ms` | number | `30000` | How long a hook command may run before it is killed. |
| `web` | object | none | Settings for the web tools. See below. |
| `prune` | object | shed after 30 days | What a prune throws away. See [Pruning](#pruning). |
| `bell` | string | `unfocused` | When a finished turn says so: `unfocused`, `always` or `never`. See below. |

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
`SYNTH_DB`, `SYNTH_SOCKET_DIR`, `SYNTH_DEBUG_LOG`, `OLLAMA_HOST`, `OLLAMA_MODEL`, `OLLAMA_API_KEY`,
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

## Pruning

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
behind it, and the file checkpoints `/rewind` would use. The cards still read: what the model was shown is on the tool call
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
