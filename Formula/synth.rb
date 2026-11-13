class Synth < Formula
  desc "Terminal coding agent for local and hosted models"
  homepage "https://github.com/aw1875/synth"
  version "0.2.1"
  license "MIT"

  if OS.mac?
    depends_on arch: :arm64

    url "https://github.com/aw1875/synth/releases/download/v0.2.1/synth-0.2.1-aarch64-macos.tar.gz"
    sha256 "1a316c6d5b99433df13f90a72c8937d9afa546489e39fb5798a87d4ba581bf77"
  else
    depends_on arch: :x86_64

    url "https://github.com/aw1875/synth/releases/download/v0.2.1/synth-0.2.1-x86_64-linux-musl.tar.gz"
    sha256 "0ccda73a1eddd01b4812f94d106fce68d812a2235c4431a62a0cd4afd08961ca"
  end

  def install
    bin.install "synth"
  end

  test do
    assert_match "synth #{version}", shell_output("#{bin}/synth --version")
    assert_match "synth [project]", shell_output("#{bin}/synth --help")
  end
end
