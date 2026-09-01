#!/usr/bin/env bash
#
# PostToolUse hook for `edit` and `write`. Formats the tree so the agent does
# not spend turns on whitespace and the diff stays readable.
#
#   { "matcher": "edit",  "command": "./examples/hooks/format-after-edit.sh" },
#   { "matcher": "write", "command": "./examples/hooks/format-after-edit.sh" }
#
# A PostToolUse hook cannot block and nothing reads what it says, so a
# formatter that fails here is silent by design: the agent has already moved
# on, and a build error will say the same thing more usefully.
set -euo pipefail

# Reading stdin keeps synth from seeing a closed pipe while it writes.
cat >/dev/null

command -v zig >/dev/null || exit 0
zig fmt src build.zig >/dev/null 2>&1 || true
