# Repository Guidelines

## Project Overview

synth is a terminal coding agent, written in Zig 0.16. It talks to a model
server (ollama, or anything speaking the OpenAI chat API), runs tools, and
renders a TUI. Commandline options and keys are documented in `README.md`.

Layout worth knowing before you dig in:

- `src/tui/` - the TUI, rendered with [vaxis](https://github.com/rockorager/libvaxis)
- `src/agent/` - the turn loop, context, tool running
- `src/tools/` - built-in tools (filesystem, shell, web, ...)
- `src/provider/` - model backends and request plumbing
- `src/core/` - config, database, hooks, skills, and shared plumbing
- `packages/mcp` - the MCP client, its own build and tests

## Build

For fast iterations during development:

`zig build`

When you believe you are done, run the test suite. It is offline and takes
about two seconds, and one command covers this repo and the `mcp` package:

`zig build test`

The mcp package's tests on their own, if you are only touching that:

`zig build test-mcp`

## Smoke tests

`zig build test` exercises the modules, not the running program. For the
program itself:

- `zig build run` launches the TUI; with no provider connected it opens the
  provider picker
- `zig build run -- prompt` prints the system prompt, a network-free check
  that the build wires up
- `zig build run -- run "<message>"` drives one real headless turn against the
  configured provider; it denies any call that would change the project unless
  `--allow` is passed, so it is safe to try first

## Code comments

The default is **no comment**. Write code that explains itself through naming
and structure instead.

A comment is only justified when it carries information that is *not
recoverable from the code*, and that a competent developer reading this file
would otherwise get wrong. In practice that means:

- A non-obvious external constraint: a terminal's behaviour, a protocol quirk,
  an allocator or platform detail that forces the code into a shape that
  otherwise looks wrong.
- A deliberate deviation: why the obvious approach was *not* taken, when the
  code alone would make a reader want to "fix" it.
- A reference that saves someone a research session: a spec section, a vendored
  dependency's expectation, a known-bug link.

Never write:

- Restatements of the code (`// increment the counter`, `// call the handler`,
  `// loop over the modes`).
- Section headers or banners inside a function (`// --- setup ---`,
  `// Step 3: cleanup`).
- Narration of your own edit or reasoning (`// changed to fix X`,
  `// this is safe because ...`, `// now uses Y`). This is talking to the
  reviewer, not to the next reader, and it is noise the moment the change is
  merged.
- Docstring-style headers that just spell out the signature in prose.
- More than one body comment in a row: a body comment is one line, never two
  or more consecutive `//` lines. If it needs a second line, it needs to be a
  doc comment (`///`, `//!`) or it should not exist.

Not every file needs a top doc comment; most files here say nothing and are
fine. If you are unsure whether a comment qualifies, it does not. Leave it out.
A change that adds zero comments is a perfectly good change; a change that
sprinkles comments over otherwise readable code will be rejected.

## Development notes

- Run `zig fmt` on changed files before committing
- Commit messages follow Conventional Commits with a scope, as in the log:
  `feat(tui): ...`, `fix(tools): ...`
- Do not use shortcuts or workarounds. Always prefer clean and idiomatic
  solutions.
- Tests must pass (`zig build test`) before a change is done. If a test fails,
  fix the cause, do not weaken the test to make it green.