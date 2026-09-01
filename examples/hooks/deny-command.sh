#!/usr/bin/env bash
#
# PreToolUse hook for `bash`. Refuses commands that should never run
# unattended, whatever the model thinks.
#
# synth's own check decides approve-versus-ask. This decides never, which is
# the part a config cannot express.
#
#   { "matcher": "bash", "command": "./examples/hooks/deny-command.sh" }
#
# Needs jq to read the command out of the payload.
set -euo pipefail

# Read the payload first: exiting with it unread leaves synth writing to a
# closed pipe.
payload=$(cat)
command -v jq >/dev/null || exit 0

command=$(jq -r '.tool_input.command // ""' <<<"$payload")

deny() {
  printf '%s\n' "$1" >&2
  exit 2
}

case "$command" in
  *"push --force"*|*"push -f"*)
    deny "rewriting published history is not the agent's call" ;;
  *"reset --hard"*)
    deny "reset --hard discards work that is not recoverable" ;;
  *"terraform apply"*|*"terraform destroy"*)
    deny "infrastructure changes go through review, not the agent" ;;
  *"kubectl delete"*|*"helm delete"*|*"helm uninstall"*)
    deny "deleting cluster resources is a person's decision" ;;
  *"npm publish"*|*"cargo publish"*)
    deny "publishing a package is a person's decision" ;;
esac

# rm -rf is fine inside the checkout and not fine above it.
if [[ "$command" == *"rm -rf"* || "$command" == *"rm -fr"* ]]; then
  case "$command" in
    *"rm -rf /"*|*"rm -fr /"*|*"rm -rf ~"*|*"rm -fr ~"*|*"rm -rf .."*|*"rm -fr .."*)
      deny "recursive delete outside the project" ;;
  esac
fi
