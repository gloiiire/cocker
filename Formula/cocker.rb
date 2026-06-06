class Cocker < Formula
  desc "Docker-compatible container engine for Apple Silicon, powered by Apple Virtualization.framework"
  homepage "https://github.com/gloiiire/cocker"
  version "0.1.0"
  url "https://github.com/gloiiire/cocker/archive/refs/tags/v#{version}.tar.gz"
  sha256 "884d2806a80fc7ef0a6294e6c0c1b03b6f28cc3c968864a330b14a99de25b74e"
  license "MIT"
  head "https://github.com/gloiiire/cocker.git", branch: "main"

  depends_on arch: :arm64
  depends_on macos: :sonoma
  depends_on xcode: ["15.0", :build]
  depends_on "zig" => :build

  def install
    # 1. Build cocker + cockerd
    system "swift", "build", "-c", "release", "--disable-sandbox"

    # 2. Build cocker-init (static Linux ARM64 binary) via zig, package into initrd.img
    cd "cocker-init" do
      system "zig", "cc",
             "-target", "aarch64-linux-musl",
             "-static", "-O2", "-Wall",
             "-o", "cocker-init", "init.c"
      system "strip", "cocker-init"
      cp "cocker-init", "initrd-staging/init"
      chmod 0755, "initrd-staging/init"
      cd "initrd-staging" do
        system "sh", "-c", "find . | cpio -o -H newc 2>/dev/null | gzip -9 > ../initrd.img"
      end
    end

    # 3. Install binaries
    bin.install ".build/release/cocker"
    bin.install ".build/release/cockerd"

    # 4. Generate + install man pages (one per subcommand)
    system "swift", "package", "--allow-writing-to-package-directory",
           "--disable-sandbox", "generate-manual", "--multi-page"
    man1.install Dir[".build/plugins/GenerateManual/outputs/CockerCLI/*.1"]

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

        cockerd uses Virtualization.framework, which macOS only permits for
        binaries signed by a real Apple developer certificate. Create one
        (free, requires only an Apple ID):

          1. Open Xcode → Settings → Accounts
          2. Sign in with your Apple ID
          3. Click "Manage Certificates" → "+" → "Apple Development"

        Then finish setup by running:
          brew postinstall cocker
      EOS
    else
      ohai "Signing cockerd with: #{cert}"
      system "codesign", "--force", "--sign", cert,
             "--entitlements", share/"cocker/cockerd.entitlements",
             bin/"cockerd"
    end

    # --- 2. Provision ~/.cocker/kernel/ (kernel symlink + initrd copy) ---
    cocker_root = Pathname.new(Dir.home)/".cocker"
    kernel_dir  = cocker_root/"kernel"
    kernel_dir.mkpath

    apple_kernel = Pathname.new(Dir.home)/"Library/Application Support/com.apple.container/kernels/default.kernel-arm64"
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

    cp share/"cocker/initrd.img", kernel_dir/"initrd.img"
    ohai "Installed initrd: #{kernel_dir}/initrd.img"
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
