class Synth < Formula
  desc "Terminal coding agent for local and hosted models"
  homepage "https://github.com/aw1875/synth"
  version "0.2.2"
  license "MIT"

  if OS.mac?
    depends_on arch: :arm64

    url "https://github.com/aw1875/synth/releases/download/v0.2.2/synth-0.2.2-aarch64-macos.tar.gz"
    sha256 "096f69546bac1f6e452f85ea033ba2cf6ed77ac2880b7c092f3cd5a863afd119"
  else
    depends_on arch: :x86_64

    url "https://github.com/aw1875/synth/releases/download/v0.2.2/synth-0.2.2-x86_64-linux-musl.tar.gz"
    sha256 "0ea005ff77ea1a135002b07561d863878e9437c3e6a8c9ade9739f30a512d733"
  end

  def install
    bin.install "synth"
  end

  test do
    assert_match "synth #{version}", shell_output("#{bin}/synth --version")
    assert_match "synth [project]", shell_output("#{bin}/synth --help")
  end
end
