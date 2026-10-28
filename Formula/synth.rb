class Synth < Formula
  desc "Terminal coding agent for local and hosted models"
  homepage "https://github.com/aw1875/synth"
  version "0.0.1-dev.149+0a1c46d"
  license "MIT"

  if OS.mac?
    depends_on arch: :arm64

    url "https://github.com/aw1875/synth/releases/download/dev/synth-dev-aarch64-macos.tar.gz"
    sha256 "e730bbfd3a3812ce1f74154cd8ea1413a7a9d090e80df2140c4e3190a638c033"
  else
    depends_on arch: :x86_64

    url "https://github.com/aw1875/synth/releases/download/dev/synth-dev-x86_64-linux-musl.tar.gz"
    sha256 "5873f8f6eff71a34644cb24bdac152ef9c08b6a1f7cbf69e4bd2730345614a28"
  end

  def install
    bin.install "synth"
  end

  test do
    assert_match "synth #{version}", shell_output("#{bin}/synth --version")
    assert_match "synth [project]", shell_output("#{bin}/synth --help")
  end
end
