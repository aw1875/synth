import argparse
import base64
import hashlib
import json
import os
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("version")
    parser.add_argument("tag")
    parser.add_argument("--publish", action="store_true")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    formula = root / "Formula/synth.rb"
    asset_version = "dev" if args.tag == "dev" else args.version
    checksums = {}
    for target in ("aarch64-macos", "x86_64-linux-musl"):
        archive = root / "release" / f"synth-{asset_version}-{target}.tar.gz"
        checksums[target] = hashlib.sha256(archive.read_bytes()).hexdigest()

    base_url = f"https://github.com/aw1875/synth/releases/download/{args.tag}"
    updated = f'''class Synth < Formula
  desc "Terminal coding agent for local and hosted models"
  homepage "https://github.com/aw1875/synth"
  version "{args.version}"
  license "MIT"

  if OS.mac?
    depends_on arch: :arm64

    url "{base_url}/synth-{asset_version}-aarch64-macos.tar.gz"
    sha256 "{checksums["aarch64-macos"]}"
  else
    depends_on arch: :x86_64

    url "{base_url}/synth-{asset_version}-x86_64-linux-musl.tar.gz"
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
    if not args.publish:
        return

    endpoint = f"repos/{os.environ['GITHUB_REPOSITORY']}/contents/Formula/synth.rb"
    current = json.loads(
        subprocess.check_output(["gh", "api", f"{endpoint}?ref=master"])
    )
    if base64.b64decode(current["content"]).decode() == updated:
        return
    payload = {
        "message": f"chore(homebrew): update synth to {args.version}",
        "content": base64.b64encode(updated.encode()).decode(),
        "sha": current["sha"],
        "branch": "master",
    }
    subprocess.run(
        ["gh", "api", "--method", "PUT", endpoint, "--input", "-"],
        input=json.dumps(payload).encode(),
        stdout=subprocess.DEVNULL,
        check=True,
    )


if __name__ == "__main__":
    main()
