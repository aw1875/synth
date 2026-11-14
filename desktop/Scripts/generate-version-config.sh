#!/bin/sh
set -eu

desktop=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
manifest="$desktop/../build.zig.zon"
version=$(sed -n 's/^[[:space:]]*\.version = "\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)",$/\1/p' "$manifest")

if [ -z "$version" ]; then
    echo "error: Expected a numeric major.minor.patch version in $manifest" >&2
    exit 1
fi

printf 'MARKETING_VERSION = %s\n' "$version" > "$desktop/SynthVersion.xcconfig"
