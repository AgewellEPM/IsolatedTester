class IsolatedTester < Formula
  desc "AI-powered isolated app testing for macOS"
  homepage "https://github.com/AgewellEPM/IsolatedTester"
  url "https://github.com/AgewellEPM/IsolatedTester/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "PLACEHOLDER_SHA256"
  license "MIT"

  depends_on :macos => :sonoma
  depends_on :xcode => ["15.4", :build]

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/isolated"
    bin.install ".build/release/isolated-mcp"
    bin.install ".build/release/isolated-http"
  end

  test do
    assert_match "USAGE", shell_output("#{bin}/isolated --help 2>&1", 0)
  end
end
