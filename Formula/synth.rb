class Synth < Formula
  desc "Terminal coding agent for local and hosted models"
  homepage "https://github.com/aw1875/synth"
  version "0.1.1"
  license "MIT"

  if OS.mac?
    depends_on arch: :arm64

    url "https://github.com/aw1875/synth/releases/download/v0.1.1/synth-0.1.1-aarch64-macos.tar.gz"
    sha256 "cb7ab278bf28f771849b433814745950d56ec0f6c961008a6ce6baf9ffad12de"
  else
    depends_on arch: :x86_64

    url "https://github.com/aw1875/synth/releases/download/v0.1.1/synth-0.1.1-x86_64-linux-musl.tar.gz"
    sha256 "9f6828700acd83c4698fa744f307ed43342e638484f285bee75c2e284ebeac87"
  end

  def install
    bin.install "synth"
  end

  test do
    assert_match "synth #{version}", shell_output("#{bin}/synth --version")
    assert_match "synth [project]", shell_output("#{bin}/synth --help")
  end
end
