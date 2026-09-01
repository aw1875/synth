#!/usr/bin/env bash
#
# UserPromptSubmit hook. Stops a prompt carrying a live credential before it
# reaches the model or the transcript.
#
#   { "command": "./examples/hooks/block-secrets.sh" }
#
# The complement to synth's own redaction, which masks secrets on the way out
# of a tool. This one covers the way in, where a pasted key would otherwise be
# stored and sent verbatim.
set -euo pipefail

payload=$(cat)

patterns=(
  'sk-[A-Za-z0-9_-]{20,}'
  'gh[pousr]_[A-Za-z0-9]{30,}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'glpat-[A-Za-z0-9_-]{16,}'
  'xox[baps]-[A-Za-z0-9-]{10,}'
  '(AKIA|ASIA)[A-Z0-9]{16}'
  'AIza[A-Za-z0-9_-]{30,}'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
)

for pattern in "${patterns[@]}"; do
  # -e matters: one pattern starts with a dash and would read as a flag.
  if grep -qE -e "$pattern" <<<"$payload"; then
    echo "that prompt looks like it carries a live credential; remove it and say it again" >&2
    exit 2
  fi
done
