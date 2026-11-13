import argparse
import hashlib
import re
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("version")
    parser.add_argument("--archives", type=Path, default=Path("release"))
    args = parser.parse_args()
    version = args.version
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        parser.error("version must be a stable release version (X.Y.Z)")

    root = Path(__file__).resolve().parents[2]
    formula = root / "Formula/synth.rb"
    current = re.search(r'^  version "([0-9]+\.[0-9]+\.[0-9]+)"$', formula.read_text(), re.MULTILINE)
    if current and tuple(map(int, current[1].split("."))) > tuple(map(int, version.split("."))):
        print(f"Homebrew already points to newer release {current[1]}")
        return

    checksums = {}
    for target in ("aarch64-macos", "x86_64-linux-musl"):
        archive = args.archives / f"synth-{version}-{target}.tar.gz"
        checksums[target] = hashlib.sha256(archive.read_bytes()).hexdigest()

    base_url = f"https://github.com/aw1875/synth/releases/download/v{version}"
    updated = f'''class Synth < Formula
  desc "Terminal coding agent for local and hosted models"
  homepage "https://github.com/aw1875/synth"
  version "{version}"
  license "MIT"

  if OS.mac?
    depends_on arch: :arm64

    url "{base_url}/synth-{version}-aarch64-macos.tar.gz"
    sha256 "{checksums["aarch64-macos"]}"
  else
    depends_on arch: :x86_64

    url "{base_url}/synth-{version}-x86_64-linux-musl.tar.gz"
    sha256 "{checksums["x86_64-linux-musl"]}"
  end

  def install
    bin.install "synth"
  end

  test do
    assert_match "synth #{{version}}", shell_output("#{{bin}}/synth --version")
    assert_match "synth [project]", shell_output("#{{bin}}/synth --help")
  end
end
'''
    formula.write_text(updated)


if __name__ == "__main__":
    main()
