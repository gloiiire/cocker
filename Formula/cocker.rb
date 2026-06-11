require "etc"

class Cocker < Formula
  desc "Docker-compatible container engine for Apple Silicon, powered by Apple Virtualization.framework"
  homepage "https://github.com/gloiiire/cocker"
  version "0.5.15"
  url "https://github.com/gloiiire/cocker/archive/refs/tags/v#{version}.tar.gz"
  # Placeholder — replace with `shasum -a 256` of the actual release tarball.
  sha256 "26cacd744a1df63e712d70f73590de82c322823f9b2ea49ccf3a56a0414a4c38"
  license "MIT"
  head "https://github.com/gloiiire/cocker.git", branch: "main"

  # Pre-compiled binary bottles published to GitHub Releases. brew
  # downloads these instead of running `swift build` on the user's
  # machine — install time drops from ~3 minutes to ~5 seconds.
  #
  # Generated automatically by `.github/workflows/bottle.yml` on every
  # release tag. The sha256 lines are rewritten by the workflow and
  # committed back to this file. `cellar :any_skip_relocation` is
  # correct here because cocker's binaries are statically positioned —
  # they don't hard-code their install prefix.
  # `bottle do` runs in a `BottleSpecification` scope that does NOT
  # have the formula's `version` method in lexical scope — using
  # `#{version}` here raises `undefined local variable 'version'` at
  # `brew info / outdated` time and bricks the tap for the user. The
  # URL has to be a literal. The `sync-homebrew-tap` workflow rewrites
  # both `version "..."` AND this `vX.Y.Z` substring on every release
  # tag so they stay in lock-step.
  bottle do
    root_url "https://github.com/gloiiire/cocker/releases/download/v0.5.15"
    sha256 cellar: :any_skip_relocation, arm64_tahoe:   "7200b3ec7f7f2ba94dd665c77fd127f4a1175c5879638ee5c7c48d51d19e13cb"
    sha256 cellar: :any_skip_relocation, arm64_sequoia: "7200b3ec7f7f2ba94dd665c77fd127f4a1175c5879638ee5c7c48d51d19e13cb"
    sha256 cellar: :any_skip_relocation, arm64_sonoma:  "7200b3ec7f7f2ba94dd665c77fd127f4a1175c5879638ee5c7c48d51d19e13cb"
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma
  depends_on xcode: ["15.0", :build]
  depends_on "zig" => :build

  def install
    # 1. Build cocker + cockerd
    system "swift", "build", "-c", "release", "--disable-sandbox"

    # 2. Build cocker-init (static Linux ARM64 binary) via zig, package into initrd.img
    cd "cocker-init" do
      # Translation units : init / cmdline / net / dns_proxy / spec / qemu
      # (orig) + exec_listener.c (Sprint 2 — vsock exec relay)
      #        + caps.c (Sprint 3 — Linux capabilities via prctl)
      #        + health_poll.c (v0.4.0 — virtiofs healthcheck worker).
      # -Wl,-s strips at link time : macOS `strip` cannot process Linux
      # ELF (silent warning, binary stays 1.6 MB). Linker-side strip
      # gets us a 70 KB statically-linked binary.
      system "zig", "cc",
             "-target", "aarch64-linux-musl",
             "-static", "-O2", "-Wall", "-Wl,-s",
             "-o", "cocker-init",
             "init.c", "cmdline.c", "net.c", "dns_proxy.c",
             "spec.c", "qemu.c", "exec_listener.c", "caps.c",
             "health_poll.c", "etc_overlay.c"
      cp "cocker-init", "initrd-staging/init"
      chmod 0755, "initrd-staging/init"
      cd "initrd-staging" do
        system "sh", "-c", "find . | cpio -o -H newc 2>/dev/null | gzip -9 > ../initrd.img"
      end
    end

    # 3. Install binaries (cocker-portfwd = subprocess séparé pour le port
    #    forwarding, signé ad-hoc sans entitlement virtualization → évite
    #    le sandbox macOS qui bloque connect() vers les IPs vmnet privées ;
    #    cocker-mcp = stdio MCP server pour Claude Desktop / agents)
    bin.install ".build/release/cocker"
    bin.install ".build/release/cockerd"
    bin.install ".build/release/cocker-portfwd"
    bin.install ".build/release/cocker-mcp"

    # 4. Install man pages.
    #
    # Two sources are tried, in order :
    #   a) `docs/man/*.1` shipped in the tarball — these are regenerated
    #      at every release on a developer machine (where the sandbox
    #      allows `swift package generate-manual`) and committed to git
    #      so end-users never pay the generation cost.
    #   b) Fallback : invoke `swift package generate-manual --multi-page`
    #      from inside the Homebrew build. This used to be the only
    #      path but the swift-argument-parser plugin tries to install
    #      its OWN sandbox via sandbox-exec, which the outer Homebrew
    #      sandbox denies with `sandbox_apply: Operation not permitted`.
    #      We keep the fallback for source-only checkouts (where the
    #      docs/ tree might be missing) ; for ordinary releases (a)
    #      already covers everything.
    prebuilt_man = Dir["docs/man/*.1"]
    if prebuilt_man.any?
      man1.install prebuilt_man
    else
      begin
        system "swift", "package", "--allow-writing-to-package-directory",
               "generate-manual", "--multi-page"
        man1.install Dir[".build/plugins/GenerateManual/outputs/CockerCLI/*.1"]
      rescue => e
        opoo "man page generation failed (#{e.class}: #{e.message.split("\n").first}) — " \
             "proceeding without ; run `swift package generate-manual --multi-page` " \
             "from a source checkout to produce them manually."
      end
    end

    # 5. Stage entitlements + initrd for post_install
    (share/"cocker").install "entitlements/cockerd.entitlements"
    (share/"cocker").install "cocker-init/initrd.img"
  end

  def post_install
    # --- 1. Sign cockerd with the user's Apple Development certificate ---
    cert = Utils.safe_popen_read(
      "security", "find-identity", "-v", "-p", "codesigning"
    ).lines.grep(/Apple Development/).first&.match(/"([^"]+)"/)&.[](1)

    if cert.nil?
      opoo <<~EOS
        No "Apple Development" signing certificate found in your Keychain.

        Falling back to ad-hoc signing with the virtualization entitlement.
        macOS still honours that entitlement for binaries compiled on the
        same machine (the local-development case Homebrew is doing here),
        so cockerd will be able to boot VMs. Upgrade to a real Apple
        Development cert if you want to copy the binary across machines :

          1. Open Xcode → Settings → Accounts
          2. Sign in with your Apple ID (free)
          3. Click "Manage Certificates" → "+" → "Apple Development"
          4. Then: brew postinstall cocker
      EOS
      ohai "Ad-hoc signing cockerd with virtualization entitlement"
      system "codesign", "--force", "--sign", "-",
             "--entitlements", share/"cocker/cockerd.entitlements",
             bin/"cockerd"
    else
      ohai "Signing cockerd with: #{cert}"
      system "codesign", "--force", "--sign", cert,
             "--entitlements", share/"cocker/cockerd.entitlements",
             bin/"cockerd"
    end

    # --- 2. Provision ~/.cocker/kernel/ (kernel symlink + initrd copy) ---
    # IMPORTANT : `Dir.home` returns Homebrew's fake-home sandbox in the
    # postinstall context (something like /private/tmp/cocker-postinstall-XXXX/),
    # so writing relative to it lands files in a tmpdir that vanishes when
    # the install ends — exactly the bug we shipped through v0.5.4 where
    # the initrd was being "installed" to /private/tmp/.../.cocker/kernel/
    # instead of the user's real ~/.cocker/kernel/.
    # `Etc.getpwuid(Process.uid).dir` always returns the real home of the
    # user running brew, regardless of any HOME env override.
    real_home   = Pathname.new(Etc.getpwuid(Process.uid).dir)
    cocker_root = real_home/".cocker"
    kernel_dir  = cocker_root/"kernel"
    kernel_dir.mkpath

    apple_kernel = real_home/"Library/Application Support/com.apple.container/kernels/default.kernel-arm64"
    if apple_kernel.exist?
      vmlinuz = kernel_dir/"vmlinuz"
      vmlinuz.unlink if vmlinuz.symlink? || vmlinuz.exist?
      vmlinuz.make_symlink(apple_kernel.realpath)
      ohai "Linked kernel: #{vmlinuz} → #{apple_kernel.realpath.basename}"
    else
      opoo <<~EOS
        Apple Container Linux kernel not found at:
          #{apple_kernel}

        Install Apple's container CLI to provision it:
          brew install container

        Then finish setup by running:
          brew postinstall cocker
      EOS
    end

    # Earlier formulas (≤ v0.5.5) symlinked kernel_dir/"initrd.img" to
    # share/cocker/initrd.img instead of copying it. FileUtils.cp refuses
    # to copy a file over a symlink that resolves to itself ("same file"
    # ArgumentError), which silently broke every subsequent upgrade's
    # post_install. Unlink first so we always end up with a real file.
    target = kernel_dir/"initrd.img"
    target.unlink if target.symlink? || target.exist?
    cp share/"cocker/initrd.img", target
    ohai "Installed initrd: #{target}"

    # --- 3. Lease-pool helper LaunchDaemon (one-time root install) ---
    # macOS vmnet's bootpd saturates around 256 DHCP leases ; without
    # this helper the user gets sudo-prompted every time they need to
    # clear the file. Skipping silently if we can't get root.
    helper_plist = Pathname.new("/Library/LaunchDaemons/com.cocker.leases-helper.plist")
    if helper_plist.exist?
      ohai "Lease helper already installed at #{helper_plist}"
    else
      tmp_plist = Pathname.new(Dir.tmpdir)/"com.cocker.leases-helper.plist"
      tmp_plist.write <<~PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>com.cocker.leases-helper</string>
          <key>ProgramArguments</key>
          <array>
            <string>/bin/sh</string>
            <string>-c</string>
            <string>while true; do if [ -f /var/run/cocker-clear-leases ]; then echo > /var/db/dhcpd_leases; rm -f /var/run/cocker-clear-leases; fi; sleep 1; done</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>StandardErrorPath</key>
          <string>/var/log/cocker-leases-helper.log</string>
        </dict>
        </plist>
      PLIST
      ohai "Installing lease helper LaunchDaemon (sudo prompt) ..."
      begin
        system "sudo", "install", "-m", "644", "-o", "root", "-g", "wheel",
               tmp_plist.to_s, helper_plist.to_s
        system "sudo", "launchctl", "bootstrap", "system", helper_plist.to_s
        ohai "Lease helper installed."
      rescue
        opoo "Could not install lease helper — `cocker daemon clear-leases` will prompt for sudo each time."
      end
      tmp_plist.unlink if tmp_plist.exist?
    end
  end

  service do
    run [opt_bin/"cockerd"]
    keep_alive true
    log_path var/"log/cockerd.log"
    error_log_path var/"log/cockerd.log"
    environment_variables HOME: Dir.home
  end

  def caveats
    <<~EOS
      cocker needs three things before it can launch containers:

      1) Apple Development signing certificate (free, one-time setup)
         Required because cockerd uses Virtualization.framework, which
         macOS only allows for binaries signed by a real Apple developer
         certificate — not an ad-hoc signature.

         How to get one:
           a) Open Xcode → Settings → Accounts
           b) Sign in with your Apple ID (free account is fine)
           c) Click "Manage Certificates" → "+" → "Apple Development"
         Then re-run:  brew postinstall cocker

      2) Apple Container Linux kernel (booted inside each container VM)
           brew install container

         If you install it after cocker, finish setup with:
           brew postinstall cocker

      3) Start the daemon
           brew services start cocker

         Logs:        #{var}/log/cockerd.log
         Verify:      cocker version
         First try:   cocker pull alpine:latest
                      cocker run -d alpine:latest -- /bin/sh -c \\
                        'while true; do date; sleep 1; done'

      Uninstalling cocker? Your container state lives in ~/.cocker
      (kept across upgrades). Remove it with:
        rm -rf ~/.cocker
    EOS
  end

  test do
    # Daemon isn't running in the test sandbox; just check the CLI binary
    # loads and shows the expected help banner.
    assert_match(/cocker/i, shell_output("#{bin}/cocker --help 2>&1", 0))
  end
end
