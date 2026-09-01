#!/usr/bin/env bash
#
# PreToolUse hook for `edit` and `write`. Refuses changes to files that are
# not the agent's to change.
#
# `matcher` takes one exact tool name, so register it twice:
#
#   { "matcher": "edit",  "command": "./examples/hooks/protect-paths.sh" },
#   { "matcher": "write", "command": "./examples/hooks/protect-paths.sh" }
#
# Needs jq to read the path out of the payload.
set -euo pipefail

# Read the payload first: exiting with it unread leaves synth writing to a
# closed pipe.
payload=$(cat)
command -v jq >/dev/null || exit 0

path=$(jq -r '.tool_input.path // ""' <<<"$payload")
[[ -n "$path" ]] || exit 0

deny() {
  printf '%s is not agent-editable: %s\n' "$path" "$1" >&2
  exit 2
}

case "$path" in
  .env|.env.*|*/.env|*/.env.*)
    deny "it holds credentials" ;;
  *.lock|*.lockb|package-lock.json|build.zig.zon.lock)
    deny "lockfiles are written by their tool, not by hand" ;;
  .github/*|.gitlab-ci.yml|Jenkinsfile)
    deny "CI config decides what runs on every push" ;;
  src/core/migrations/*)
    deny "an applied migration is history; add a new one instead" ;;
  *.pem|*.key|*id_rsa*|*id_ed25519*)
    deny "it is a private key" ;;
esac
