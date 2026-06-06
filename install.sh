#!/bin/bash
# Cocker installer — build, sign, install et démarre cockerd via launchd
set -e

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
MAN_DIR="$PREFIX/share/man/man1"
COCKER_ROOT="$HOME/.cocker"
SIGNING_IDENTITY="${COCKER_SIGN_ID:-}"
APPLE_CONTAINER_KERNEL="$HOME/Library/Application Support/com.apple.container/kernels/default.kernel-arm64"

color() { printf "\033[%sm%s\033[0m\n" "$1" "$2"; }
info()  { color "1;36" "==> $1"; }
ok()    { color "1;32" "✓ $1"; }
warn()  { color "1;33" "⚠ $1"; }
err()   { color "1;31" "✗ $1"; exit 1; }

# 1. Prérequis
info "Vérification des prérequis..."
[ "$(uname -s)" = "Darwin" ] || err "Cocker nécessite macOS"
[ "$(uname -m)" = "arm64" ] || err "Cocker nécessite Apple Silicon"
sw_ver=$(sw_vers -productVersion | cut -d. -f1)
[ "$sw_ver" -ge 14 ] || err "Cocker nécessite macOS 14+ (tu es sur $sw_ver)"
ok "macOS $sw_ver Apple Silicon détecté"

command -v swift >/dev/null || err "Swift non trouvé. Installe Xcode ou les Command Line Tools."
ok "Swift trouvé : $(swift --version | head -1 | awk '{print $4}')"

command -v zig >/dev/null || {
  warn "zig non trouvé (nécessaire pour cocker-init)"
  read -p "Installer via Homebrew ? [Y/n] " r
  [[ "$r" =~ ^([Nn]|[Nn][Oo])$ ]] || brew install zig
}
ok "zig $(zig version) trouvé"

# 2. Apple Container kernel
if [ ! -f "$APPLE_CONTAINER_KERNEL" ]; then
  warn "Kernel Linux non trouvé ($APPLE_CONTAINER_KERNEL)"
  read -p "Installer apple/container via Homebrew ? [Y/n] " r
  [[ "$r" =~ ^([Nn]|[Nn][Oo])$ ]] && err "Kernel requis pour lancer des containers."
  brew install container
fi
ok "Kernel Apple container : $(readlink "$APPLE_CONTAINER_KERNEL" | xargs basename)"

# 3. Signing identity
if [ -z "$SIGNING_IDENTITY" ]; then
  SIGNING_IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)".*/\1/')
fi
[ -n "$SIGNING_IDENTITY" ] || err "Pas de certificat 'Apple Development' trouvé. Crée-en un dans Xcode → Settings → Accounts."
ok "Signing identity : $SIGNING_IDENTITY"

# 4. Build
info "Building cocker + cockerd (release)..."
swift build -c release
ok "Swift build OK"

info "Generating man pages..."
swift package --allow-writing-to-package-directory generate-manual --multi-page >/dev/null
MAN_SRC=".build/plugins/GenerateManual/outputs/CockerCLI"
[ -d "$MAN_SRC" ] && [ "$(ls -A "$MAN_SRC" 2>/dev/null | wc -l)" -gt 0 ] || err "Man page generation produced no output"
ok "$(ls "$MAN_SRC"/*.1 | wc -l | tr -d ' ') man pages generated"

info "Building cocker-init (Linux ARM64 static)..."
(cd cocker-init &&
 zig cc -target aarch64-linux-musl -static -O2 -Wall -o cocker-init init.c cmdline.c net.c dns_proxy.c spec.c qemu.c &&
 strip cocker-init &&
 cp cocker-init initrd-staging/init &&
 chmod +x initrd-staging/init &&
 (cd initrd-staging && find . | cpio -o -H newc 2>/dev/null) | gzip -9 > initrd.img)
ok "cocker-init compilé + initrd.img créé ($(ls -lh cocker-init/initrd.img | awk '{print $5}'))"

# 5. Sign cockerd
info "Signing cockerd avec entitlements Virtualization..."
codesign --force --sign "$SIGNING_IDENTITY" \
  --entitlements entitlements/cockerd.entitlements \
  .build/release/cockerd
ok "cockerd signé"

# 6. Install
info "Installation dans $BIN_DIR..."
mkdir -p "$BIN_DIR" "$MAN_DIR"
install -m 755 .build/release/cocker "$BIN_DIR/cocker"
install -m 755 .build/release/cockerd "$BIN_DIR/cockerd"
install -m 755 .build/release/cocker-portfwd "$BIN_DIR/cocker-portfwd"
install -m 644 "$MAN_SRC"/*.1 "$MAN_DIR/"
ok "Binaires + man pages installés ($MAN_DIR)"

# 7. Cocker data dir
info "Configuration $COCKER_ROOT..."
mkdir -p "$COCKER_ROOT/kernel"
[ -e "$COCKER_ROOT/kernel/vmlinuz" ] && rm -f "$COCKER_ROOT/kernel/vmlinuz"
ln -sf "$APPLE_CONTAINER_KERNEL" "$COCKER_ROOT/kernel/vmlinuz"
cp cocker-init/initrd.img "$COCKER_ROOT/kernel/initrd.img"
ok "Kernel et initrd configurés"

# 8. launchd plist (auto-start cockerd au boot)
info "Configuration launchd..."
PLIST="$HOME/Library/LaunchAgents/com.cocker.cockerd.plist"
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.cocker.cockerd</string>
  <key>ProgramArguments</key><array>
    <string>$BIN_DIR/cockerd</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$COCKER_ROOT/cockerd.log</string>
  <key>StandardErrorPath</key><string>$COCKER_ROOT/cockerd.log</string>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>$HOME</string>
  </dict>
</dict></plist>
PLIST_EOF

# Stop daemon existant, reload
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
ok "cockerd démarré via launchd (logs : $COCKER_ROOT/cockerd.log)"

sleep 1

# 9. Verify
echo
info "Vérification..."
if "$BIN_DIR/cocker" version >/dev/null 2>&1; then
  "$BIN_DIR/cocker" version
  ok "cocker fonctionne"
else
  warn "cocker version a échoué — vérifie $COCKER_ROOT/cockerd.log"
fi

# 10. PATH advice
echo
case ":$PATH:" in
  *":$BIN_DIR:"*) ok "$BIN_DIR déjà dans ton PATH" ;;
  *)
    warn "$BIN_DIR n'est pas dans ton PATH"
    echo "    Ajoute à ton ~/.zshrc :"
    echo "        export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac

MAN_ROOT="$PREFIX/share/man"
if ! manpath 2>/dev/null | tr ':' '\n' | grep -qx "$MAN_ROOT"; then
  warn "$MAN_ROOT n'est pas dans ton MANPATH (man cocker ne fonctionnera pas)"
  echo "    Ajoute à ton ~/.zshrc :"
  echo "        export MANPATH=\"$MAN_ROOT:\$(manpath 2>/dev/null)\""
else
  ok "$MAN_ROOT dans MANPATH — essaye : man cocker"
fi

echo
color "1;32" "🎉 Cocker installé. Essaye :"
echo "    cocker pull alpine:latest"
echo "    cocker run -d alpine:latest -- /bin/sh -c 'while true; do date; sleep 1; done'"
echo "    cocker ps"
echo
echo "Pour stopper le daemon : launchctl bootout gui/$(id -u) $PLIST"
echo "Pour redémarrer        : launchctl kickstart -k gui/$(id -u)/com.cocker.cockerd"
