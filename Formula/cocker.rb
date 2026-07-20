require "etc"

class Cocker < Formula
  desc "Docker-compatible container engine for Apple Silicon, powered by Apple Virtualization.framework"
  homepage "https://github.com/gloiiire/cocker"
  version "0.7.13.1"
  url "https://github.com/gloiiire/cocker/archive/refs/tags/v#{version}.tar.gz"
  # Placeholder — replace with `shasum -a 256` of the actual release tarball.
  sha256 "REPLACE_WITH_RELEASE_TARBALL_SHA256"
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
    root_url "https://github.com/gloiiire/cocker/releases/download/v0.7.13.1"
    sha256 cellar: :any_skip_relocation, all:      "REPLACE_BOTTLE_SHA256_ALL"
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma
  depends_on xcode: ["15.0", :build]
  depends_on "zig" => :build

  # cocker runs Linux containers inside per-container VMs spun up via Apple's
  # Virtualization.framework, but the Linux kernel itself (vmlinuz) comes from
  # apple's `container` formula — we reuse its kernel rather than vendoring one
  # in our own bottle. Without this dep, `cockerd setup` would hit the cold-
  # start "no kernel found" branch on a fresh machine.
  depends_on "container"

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

    # 6. Kiro / Fig autocomplete spec.
    #
    # Staged under <prefix>/share/cocker/completions/kiro/ so it survives
    # `brew uninstall` cleanly and lives in the cellar like every other
    # data asset. post_install (below) symlinks / copies it into the
    # user's ~/.fig/autocomplete/build/ directory when Kiro CLI is
    # detected — that's the path the bundled Kiro autocomplete reads
    # custom specs from (confirmed by inspecting the
    # /Applications/Kiro CLI.app/Contents/Resources/autocomplete/ bundle :
    # `strings | grep '~/.fig'` shows `~/.fig/autocomplete/build/`).
    (share/"cocker/completions/kiro").install "completions/kiro/cocker.ts"
    (share/"cocker/completions/kiro").install "completions/kiro/README.md"
  end

  def post_install
    # --- 1. Ad-hoc sign cockerd with the virtualization entitlement ---
    #
    # Homebrew runs post_install inside a seatbelt sandbox that denies
    # filesystem access to ~/Library/Keychains/. Inside that sandbox,
    # `security find-identity` returns an empty list even when the
    # user has a perfectly good Apple Development cert installed —
    # `security` succeeds, the keychain file read silently fails. So
    # we don't try to detect a real cert here ; we always ad-hoc sign,
    # which works inside the sandbox AND lets cockerd boot VMs on the
    # same machine it was signed on (macOS honors the virtualization
    # entitlement for ad-hoc signatures of locally-built binaries).
    #
    # Users who want a TeamIdentifier-bearing signature (required to
    # copy the binary across machines, or to satisfy stricter signing
    # policies) should run :
    #
    #     cocker daemon resign
    #
    # which runs in the user's shell context, reads the keychain
    # normally, and re-signs cockerd in place.
    require "open3"
    ohai "Ad-hoc signing cockerd with virtualization entitlement"
    cs_out, cs_err, cs_status = Open3.capture3(
      "/usr/bin/codesign", "--force",
      "--sign", "-",
      "--entitlements", (share/"cocker/cockerd.entitlements").to_s,
      (bin/"cockerd").to_s
    )
    unless cs_status.success?
      opoo "codesign failed (exit #{cs_status.exitstatus}): #{cs_err.strip}"
      opoo "cockerd may not be able to launch VMs until re-signed manually."
    end
    # codesign prints "replacing existing signature" to stderr on every
    # upgrade — informational, not a failure. ohai (not opoo) keeps
    # it in the calm-log lane.
    ohai "codesign: #{cs_err.strip}" unless cs_err.empty?
    ohai cs_out.strip unless cs_out.empty?

    # Ad-hoc signing is enough to boot VMs on this Mac, so this is a
    # calm ohai note, not an opoo warning — nothing is broken. Only a
    # user moving the binary to another machine needs a real cert.
    ohai <<~EOS
      cockerd is ad-hoc signed — enough for macOS to let it boot VMs on
      this Mac. Only if you copy the binary to another machine (or hit a
      stricter signing policy) do you need a real Apple Development cert:

        cocker daemon resign        (re-run after each `brew upgrade cocker`)
    EOS

    # --- 2. Provision ~/.cocker/kernel/ (kernel symlink + initrd copy) ---
    #
    # Brew's post_install runs inside a seatbelt sandbox that denies
    # writes to ~/. The Pathname / FileUtils.cp calls below RAISE
    # SystemCallError when the sandbox denies them, which historically
    # surfaced as "Warning: The post-install step did not complete
    # successfully" — alarming, but actually harmless because cocker's
    # `~/.cocker/kernel/initrd.img` was created as a SYMLINK to
    # `<prefix>/share/cocker/initrd.img` on the very first install,
    # and brew updates the file in <prefix>/share/ normally, so the
    # user keeps getting the freshest initrd through the symlink.
    #
    # Wrap the whole block in rescue so a sandbox-denied write doesn't
    # blow up the install. If anything failed, point the user at
    # `cocker daemon setup` which runs the same steps from their
    # shell (outside the sandbox) and can actually write to ~/.cocker/.
    setup_ok = true
    begin
      # `Dir.home` returns Homebrew's fake-home sandbox in the
      # postinstall context (something like /private/tmp/cocker-postinstall-XXXX/).
      # `Etc.getpwuid(Process.uid).dir` returns the real home regardless.
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
      end

      # Earlier formulas (≤ v0.5.5) symlinked kernel_dir/"initrd.img" to
      # share/cocker/initrd.img. FileUtils.cp refuses to copy a file over
      # a symlink resolving to itself ("same file" ArgumentError) so we
      # unlink first.
      target = kernel_dir/"initrd.img"
      target.unlink if target.symlink? || target.exist?
      cp share/"cocker/initrd.img", target
      ohai "Installed initrd: #{target}"
    rescue StandardError => e
      setup_ok = false
      opoo <<~EOS
        Could not refresh ~/.cocker/kernel/ from inside the Homebrew sandbox
        (#{e.class}: #{e.message.split("\n").first}). cocker still works via
        the existing symlinks. To do a clean refresh, run :

          cocker daemon setup

        from your shell at any time after install.
      EOS
    end

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

    # --- 4. Kiro / Fig autocomplete spec hint ---
    #
    # Homebrew's post_install runs inside a seatbelt sandbox that denies
    # writes to ~/.fig/ — same constraint as the kernel/initrd section
    # above. We therefore can't drop the spec ourselves from here ; we
    # just point the user at `cocker autocomplete install` which runs
    # from their shell (outside the sandbox) and does the copy cleanly
    # in one command.
    spec_src = share/"cocker/completions/kiro/cocker.ts"
    kiro_app = Pathname.new("/Applications/Kiro CLI.app")
    fig_app  = Pathname.new("/Applications/Fig.app")
    has_kiro = kiro_app.exist? || fig_app.exist?

    if has_kiro && spec_src.exist?
      ohai "Kiro CLI detected. Finish autocomplete setup from your shell with :"
      ohai "    cocker autocomplete install"
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
      cocker is signed and ready — it runs out of the box on this Mac.
      The Apple Container Linux kernel it boots comes bundled via the
      `container` dependency, installed automatically alongside cocker.

      Start the daemon:
           brew services start cocker

         Logs:        #{var}/log/cockerd.log
         Verify:      cocker version
         First try:   cocker pull alpine:latest
                      cocker run -d alpine:latest -- /bin/sh -c \\
                        'while true; do date; sleep 1; done'

         Kernel not found on first run? A fresh install's post-install
         step is sandboxed from writing ~/.cocker — provision it once:
           cocker daemon setup

      Signing (only if you move the binary between Macs)
        cockerd is ad-hoc signed at install — enough for macOS to let it
        boot VMs on THIS machine. You only need a real Apple Development
        cert to copy the binary to another Mac or satisfy a stricter
        policy:
          a) Xcode → Settings → Accounts → sign in (a free Apple ID works)
          b) Manage Certificates → "+" → "Apple Development"
          c) cocker daemon resign        # re-run after each brew upgrade

      Autocomplete (optional — Kiro CLI)
        If you use Kiro CLI (https://kiro.dev), install the shipped spec:
          cocker autocomplete install
        then restart your terminal.

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
