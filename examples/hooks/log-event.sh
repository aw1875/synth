#!/usr/bin/env bash
set -euo pipefail

payload=$(cat)
printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$payload" >> .synth-hooks.log
