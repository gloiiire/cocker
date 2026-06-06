class Cocker < Formula
  desc "Docker-compatible container engine for Apple Silicon, powered by Apple Virtualization.framework"
  homepage "https://github.com/gloiiire-/cocker"
  url "https://github.com/gloiiire-/cocker/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/gloiiire-/cocker.git", branch: "main"

  depends_on :macos => :sonoma
  depends_on xcode: ["15.0", :build]

  def install
    system "swift", "build", "-c", "release",
           "--disable-sandbox"
    bin.install ".build/release/cocker"
    bin.install ".build/release/cockerd"

    # Entitlements for Virtualization.framework
    entitlements = prefix/"cockerd.entitlements"
    entitlements.write <<~EOS
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
        <key>com.apple.security.virtualization</key><true/>
        <key>com.apple.vm.networking</key><true/>
        <key>com.apple.security.network.client</key><true/>
        <key>com.apple.security.network.server</key><true/>
      </dict></plist>
    EOS
    system "codesign", "--force", "--sign", "-",
           "--entitlements", entitlements.to_s,
           bin/"cockerd"
  end

  service do
    run [opt_bin/"cockerd"]
    keep_alive true
    log_path var/"log/cockerd.log"
    error_log_path var/"log/cockerd.log"
    environment_variables COCKER_DNS_PORT: "5300"
  end

  test do
    assert_match "0.1.0", shell_output("#{bin}/cocker version")
  end
end
