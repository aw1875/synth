# Contributing

The tree is mapped in [Layout](../README.md#layout) in the README. It is worth
reading first: the turn loop is `src/agent/`, the built-in tools `src/tools/`,
the model backends `src/provider/`, the MCP client its own `packages/mcp/`
package, and knowing which is which makes the sections below concrete.

## Setup

Zig 0.16 (CI pins 0.16.0) and nothing else. A build needs no model server; the
tests never touch the network.

```sh
zig build              # binary in zig-out/bin/synth
zig build test         # whole tree plus the mcp package, about ten seconds
zig build test-mcp     # the mcp client alone
zig build release      # macos-arm64, linux-x86_64-gnu and -musl into zig-out/<triple>
```

Smoke tests for the running program rather than the modules:

```sh
zig build run -- prompt        # prints the system prompt; no network, no TUI
zig build run -- run "<msg>"   # one real headless turn; denies writes unless --allow
zig build run                  # the TUI; opens the provider picker with none configured
```

A debug build keeps `config.json`, `auth.json` and `synth.db` in the checkout,
so running your build never touches installed state. Point it at a throwaway
project directory anyway; `SYNTH_DB` moves the database if you would rather.

## How the tests are shaped

Tests are `test` blocks in the same file as what they cover; there is no
separate test directory to mirror. The runner
([test_runner.zig](../test_runner.zig)) prints one line per module and names
any test slower than 250ms, so a slow one is usually visible on its own.

The turn loop is tested through a fixture in
[src/agent/loop.zig](../src/agent/loop.zig): a temp project directory, a real
registry, and a `FakeProvider` that answers with scripted turns, so approval
and tool-batch behavior is exercised end to end without a model. When you fix
a bug, add the test that would have caught it there or beside the code.

## Common changes

**A new tool** - `src/tools/` holds one file per group, each exporting an
`all` array of `Tool` values ([src/tools/tool.zig](../src/tools/tool.zig)):
`name`, `description`, the argument JSON schema, a handler, and the flags that
decide how the agent treats it -

- `read_only` - runs without an approval prompt
- `parallel` - may run beside other calls in one batch (a different question
  from `read_only`; `task` is read-only and still runs alone)
- `timeout_ms`, `max_result_bytes` - opt out of the defaults for tools that
  legitimately run long or return documents

Register it in `Registry.init` in [registry.zig](../src/tools/registry.zig),
then decide which modes see it: the per-mode tool lists in
[src/agent/agent.zig](../src/agent/agent.zig) are explicit (`reading`,
`reading_and_delegating`, plus overrides per mode), so a new tool is invisible
to every mode until named.

**A new config key** - three places: the parsed struct in
[src/core/config.zig](../src/core/config.zig) with its default, the property
in [config.schema.json](../config.schema.json) (editors read that URL from a
fresh config file), and a row in [configuration.md](configuration.md). A test
in config.zig covers the default and the loading.

**A mode change** - modes are data in [agent.zig](../src/agent/agent.zig):
the tool list, the step budget, and the `<mode>` block prepended to the system
prompt. The user-facing side is [usage.md](usage.md).

**A provider fix** - `debug_log` in `config.json` appends every request and
reply to a file; that is the first place to look when a model goes quiet, and
usually the fastest way to see what a provider actually sent.

## Before opening a PR

1. `zig fmt` the files you touched.
2. `zig build test` green.
3. Docs that describe the behavior changed too - keys in
   [configuration.md](configuration.md), commands in [cli.md](cli.md), the
   schema for new config keys.
4. Conventional Commits with a scope, as in the log: `feat(tui): ...`,
   `fix(tools): ...`. One logical change per commit.

House style lives in [AGENTS.md](../AGENTS.md): self-explaining code, comments
only for what the code cannot say.
