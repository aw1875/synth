#!/bin/sh
set -eu

desktop=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(dirname "$desktop")
derived_data=${SYNTH_DERIVED_DATA:-"$desktop/DerivedData"}
zig=${ZIG:-zig}

mkdir -p "$derived_data"
derived_data=$(CDPATH='' cd -- "$derived_data" && pwd)
engine_prefix="$derived_data/engine"

cd "$repo"
"$zig" build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos.26.0 --prefix "$engine_prefix"

xcodebuild -project "$desktop/Synth.xcodeproj" -scheme Synth -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived_data" \
    "SYNTH_ENGINE=$engine_prefix/bin/synth" "$@" build

printf '%s\n' "$derived_data/Build/Products/Release/Synth.app"
