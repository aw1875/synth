#!/usr/bin/env bash
#
# Usage: ./.github/scripts/package.sh <version>
set -euo pipefail

version="${1:?usage: package.sh <version>}"

# musl covers linux without a glibc to match, so gnu is built but not shipped.
targets=(aarch64-macos x86_64-linux-musl)

rm -rf release
mkdir -p release

for triple in "${targets[@]}"; do
  if [ ! -x "zig-out/$triple/synth" ]; then
    echo "::error::zig build release produced no binary for $triple"
    exit 1
  fi
  tar -C "zig-out/$triple" -czf "release/synth-${version}-${triple}.tar.gz" synth
done

ls -l release
