#!/bin/sh
# Installs the synth binary from a GitHub release.
#
#   curl -fsSL https://getsynth.sh/install | sh
#   curl -fsSL https://getsynth.sh/install | sh -s 0.2.0
#   curl -fsSL https://getsynth.sh/install | sh -s dev
#
# The argument picks a release; the latest one otherwise. SYNTH_INSTALL_DIR
# picks where the binary goes; ~/.local/bin otherwise.
set -eu

repo="aw1875/synth"

say() {
    printf 'synth: %s\n' "$1"
}

fail() {
    printf 'synth: %s\n' "$1" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

triple() {
    os=$(uname -s)
    arch=$(uname -m)
    case "$os/$arch" in
        Darwin/arm64) echo aarch64-macos ;;
        Linux/x86_64 | Linux/amd64) echo x86_64-linux-musl ;;
        *) fail "no build for $os $arch yet; build from source: https://github.com/$repo#build-from-source" ;;
    esac
}

latest() {
    location=$(curl -fsSI "https://github.com/$repo/releases/latest" | tr -d '\r' | sed -n 's/^[Ll]ocation: .*\/tag\/v//p')
    [ -n "$location" ] || fail "could not find the latest release"
    echo "$location"
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

main() {
    need curl
    need tar

    target=$(triple)
    [ $# -le 1 ] || fail "usage: install.sh [version]"
    version=${1:-$(latest)}
    version=${version#v}
    tag=$([ "$version" = dev ] && echo dev || echo "v$version")
    archive="synth-$version-$target.tar.gz"
    base="https://github.com/$repo/releases/download/$tag"
    dir=${SYNTH_INSTALL_DIR:-$HOME/.local/bin}

    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT INT TERM

    say "downloading $archive"
    curl -fsSL -o "$work/$archive" "$base/$archive" || fail "no $archive in release $tag"

    if curl -fsSL -o "$work/SHA256SUMS" "$base/SHA256SUMS" 2>/dev/null; then
        expected=$(grep " $archive\$" "$work/SHA256SUMS" | cut -d' ' -f1)
        [ -n "$expected" ] || fail "SHA256SUMS does not list $archive"
        [ "$(sha256 "$work/$archive")" = "$expected" ] || fail "$archive does not match its checksum"
    else
        say "release $tag publishes no checksums; skipping verification"
    fi

    tar -xzf "$work/$archive" -C "$work" synth
    mkdir -p "$dir"
    mv "$work/synth" "$dir/synth"
    chmod 755 "$dir/synth"
    say "installed $("$dir/synth" --version 2>/dev/null || echo "$version") to $dir/synth"

    case ":$PATH:" in
        *":$dir:"*) ;;
        *) say "$dir is not on your PATH; add it, e.g. export PATH=\"$dir:\$PATH\"" ;;
    esac
}

main "$@"
