#!/usr/bin/env bash
#
# Usage: ./.github/scripts/package.sh <version>
set -euo pipefail

version="${1:?usage: package.sh <version>}"

# musl covers linux without a glibc to match, so gnu is built but not shipped.
targets=(aarch64-macos x86_64-linux-musl aarch64-linux-musl)

rm -rf release
mkdir -p release

for triple in "${targets[@]}"; do
  if [ ! -x "zig-out/$triple/synth" ]; then
    echo "::error::zig build release produced no binary for $triple"
    exit 1
  fi
  tar -C "zig-out/$triple" -czf "release/synth-${version}-${triple}.tar.gz" synth
done

# A dev build has no Debian version to give it, so only releases get a .deb.
if [ "$version" != dev ]; then
  for triple in "${targets[@]}"; do
    case "$triple" in
      x86_64-linux-*) arch=amd64 ;;
      aarch64-linux-*) arch=arm64 ;;
      *) continue ;;
    esac

    root=$(mktemp -d)
    chmod 755 "$root"
    install -Dm755 "zig-out/$triple/synth" "$root/usr/bin/synth"
    install -Dm644 LICENSE "$root/usr/share/doc/synth/copyright"
    mkdir -p "$root/DEBIAN"
    cat > "$root/DEBIAN/control" <<EOF
Package: synth
Version: $version
Architecture: $arch
Maintainer: synth <noreply@getsynth.sh>
Installed-Size: $(du -sk --apparent-size "$root/usr" | cut -f1)
Section: devel
Priority: optional
Homepage: https://getsynth.sh
Description: Terminal coding agent for local and hosted models
EOF
    dpkg-deb --root-owner-group --build "$root" "release/synth_${version}_${arch}.deb"
    rm -rf "$root"
  done
fi

(cd release && sha256sum -- synth[-_]* > SHA256SUMS)

ls -l release
