# Using synth

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

## Searching

`synth session search <text>`, or `/search <text>` inside the TUI, looks through
every transcript in the project. What was said comes first and tool output
after, since a search is usually after the conversation rather than a file a
tool printed.

The match is plain text, not a query language, so `100%` searches for `100%`.

## Modes

`tab` cycles three. **Build** can read, write and run. **Plan** is read
only and answers with a plan rather than changes. **Review** can read and run
commands - tests, `git diff`, a build - but cannot edit.

Anything that changes the project or runs a command asks first, and a preset of
read-only shell commands skips the prompt.

"Allow always" remembers the answer for the project, as narrowly as it can: a
shell command is allowed by its subcommand (`git commit *` does not cover
`git push`), and a program without one by the exact command. `↑`/`↓` on the
prompt widens or narrows that before it is saved. `/permissions` lists what is
allowed; `enter` edits a pattern, `del` removes it, and typing a command that is
not there offers to add it. A change holds in every session on the project at
once.

### Auto approvals

`/approvals auto` (or `"approvals": "auto"` in `config.json`) hands those
decisions to the session's own model instead. Reads, the safe commands, narrow
allowances and edits inside the project run as before; everything else is
judged first, by a model shown only what you asked for and the calls the agent
has made - not what the agent said, and not what any tool returned. Text
planted in a file reaches it only inside a call's arguments (a heredoc, a file
being written), fenced off as data it is told not to follow. The safe commands
skip it as they skip the prompt, wherever they point: `cat ~/.ssh/id_rsa` runs
unjudged unless `auto_approve_safe_commands` is off. It blocks what looks destructive,
reaches outside the project, sends data out, touches credentials, or goes past
the task, and a block reaches the agent as a refused call with the reason.
Allowances that would run anything (`python3 *`, `npm run *`) are set aside
while it judges. Three blocks in a row, or twenty in a session, hand decisions
back to you. `/approvals all` runs everything without asking; `/approvals ask`
goes back to the prompt.

### Rewind

`/rewind` undoes what turns did to files. Before `write` or `edit` first changes
a file in a turn, synth keeps what the file held; `/rewind` lists the prompts
that changed files, shows what going back to before one would put back, flags
anything changed since by other means, and restores it. Files changed through
the shell are not tracked, and the transcript stays as it was.
