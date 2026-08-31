# Template formula. The release workflow (.github/workflows/release.yml) renders this on each
# tag — substituting VERSION_PLACEHOLDER and the two SHA256 placeholders with real values — and
# publishes the result to the Homebrew tap. Releases use bare semver tags (no `v` prefix), so the
# download URL must not include a `v`. Do not hand-fill the placeholders here.
class Amoo < Formula
  desc "AI-driven mobile testing framework for iOS and Android"
  homepage "https://github.com/ArjangConsulting/amoo-ai"
  license "MIT"
  version "VERSION_PLACEHOLDER"

  on_macos do
    url "https://github.com/ArjangConsulting/amoo-ai/releases/download/#{version}/amoo-#{version}-macos-universal.tar.gz"
    sha256 "MACOS_SHA256_PLACEHOLDER"
  end

  on_linux do
    url "https://github.com/ArjangConsulting/amoo-ai/releases/download/#{version}/amoo-#{version}-linux-static.tar.gz"
    sha256 "LINUX_SHA256_PLACEHOLDER"
  end

  def install
    bin.install "amoo"
    prefix.install "CompanionApps"
  end

  test do
    assert_match "Usage: amoo <command> [options]", shell_output("#{bin}/amoo --help")
    assert_match(/\A\d+\.\d+\.\d+/, shell_output("#{bin}/amoo --version"))
    assert_path_exists prefix/"CompanionApps/Android/gradlew"
    assert_path_exists prefix/"CompanionApps/iOS/project.yml" if OS.mac?
  end
end
