class Synth < Formula
  desc "Terminal coding agent for local and hosted models"
  homepage "https://github.com/aw1875/synth"
  version "0.2.0"
  license "MIT"

  if OS.mac?
    depends_on arch: :arm64

    url "https://github.com/aw1875/synth/releases/download/v0.2.0/synth-0.2.0-aarch64-macos.tar.gz"
    sha256 "d84bd40a7b1944d220e0669df8cbc2613ff4c5e93cff108a4c20a8708622f9c7"
  else
    depends_on arch: :x86_64

    url "https://github.com/aw1875/synth/releases/download/v0.2.0/synth-0.2.0-x86_64-linux-musl.tar.gz"
    sha256 "3f59e4e8befd7411c2cf62941ea22e154e3d9ecbfa0e275e6bdd659db92d3bc5"
  end

  def install
    bin.install "synth"
  end

  test do
    assert_match "synth #{version}", shell_output("#{bin}/synth --version")
    assert_match "synth [project]", shell_output("#{bin}/synth --help")
  end
end
