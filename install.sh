#!/bin/bash
# Cocker installer — build, sign, install et démarre cockerd via launchd.
#
# Mode prod (par défaut) : binaires `cocker` / `cockerd`, data dir
# ~/.cocker, launchd label com.cocker.cockerd.
#
# Mode dev (SUFFIX=-dev) : install parallèle side-by-side. Binaires
# `cocker-dev` / `cockerd-dev`, data dir ~/.cocker-dev, launchd label
# com.cocker.cockerd-dev. Les deux daemons peuvent tourner simultanément
# sans collision (sockets et données séparés).
#
# Exemples :
#   ./install.sh                      # install prod (écrase la prod existante)
#   SUFFIX=-dev ./install.sh          # install dev side-by-side
#   COCKER_DATA_DIR=~/foo ./install.sh # override la data dir manuellement
set -e

# SUFFIX (vide ou `-dev`) — ajouté au nom de chaque binaire, à la data
# dir, au label launchd, et au plist. Doit commencer par `-` quand non-vide
# pour rester human-readable.
SUFFIX="${SUFFIX:-}"
if [ -n "$SUFFIX" ] && [ "${SUFFIX:0:1}" != "-" ]; then
  SUFFIX="-$SUFFIX"
fi

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
LIBEXEC_DIR="$PREFIX/libexec/cocker$SUFFIX"
MAN_DIR="$PREFIX/share/man/man1"
COCKER_ROOT="${COCKER_DATA_DIR:-$HOME/.cocker$SUFFIX}"
COCKER_SOCKET="$COCKER_ROOT/cocker.sock"
LAUNCHD_LABEL="com.cocker.cockerd$SUFFIX"
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
# All translation units : init.c is the main PID 1 entry, the rest are
# split-by-responsibility modules. -Wl,-s strips at link time (macOS
# `strip` silently fails on Linux ELF — bloat from 70 KB → 1.6 MB if
# you skip it).
(cd cocker-init &&
 zig cc -target aarch64-linux-musl -static -O2 -Wall -Wl,-s -o cocker-init \
     init.c cmdline.c net.c dns_proxy.c spec.c qemu.c \
     exec_listener.c caps.c health_poll.c etc_overlay.c &&
 cp cocker-init initrd-staging/init &&
 chmod +x initrd-staging/init &&
 (cd initrd-staging && find . | cpio -o -H newc 2>/dev/null) | gzip -9 > initrd.img)
ok "cocker-init compilé + initrd.img créé ($(ls -lh cocker-init/initrd.img | awk '{print $5}'))"

# 5. Sign all binaries
#
# Apple Dev signing (with `$SIGNING_IDENTITY` from your keychain) is
# applied to EVERY binary, not just cockerd. Reason : macOS Sequoia /
# Tahoe (15+) tightened amfid + Launch Constraints. Ad-hoc signed
# binaries (codesign --sign -) routinely SIGKILL when executed outside
# their build dir — `cocker --version` silently exits 137 with no output
# is the typical symptom. Signing with your real Apple Development cert
# gives each binary a strong identity that macOS trusts everywhere,
# regardless of where you copy or move it.
#
# cockerd additionally gets the Virtualization entitlement embedded
# inside its signature — without that entitlement macOS refuses to
# initialize a VZVirtualMachine.
info "Signing all binaries with $SIGNING_IDENTITY..."
codesign --force --sign "$SIGNING_IDENTITY" \
  --entitlements entitlements/cockerd.entitlements \
  .build/release/cockerd
codesign --force --sign "$SIGNING_IDENTITY" .build/release/cocker
codesign --force --sign "$SIGNING_IDENTITY" .build/release/cocker-mcp
codesign --force --sign "$SIGNING_IDENTITY" .build/release/cocker-portfwd
ok "All 4 binaries signed (cockerd with entitlements, others bare)"

# 6. Install
info "Installation dans $BIN_DIR..."
mkdir -p "$BIN_DIR" "$MAN_DIR"

if [ -z "$SUFFIX" ]; then
  # Mode prod : binaires direct dans BIN_DIR avec nom standard.
  install -m 755 .build/release/cocker "$BIN_DIR/cocker"
  install -m 755 .build/release/cockerd "$BIN_DIR/cockerd"
  install -m 755 .build/release/cocker-portfwd "$BIN_DIR/cocker-portfwd"
  install -m 755 .build/release/cocker-mcp "$BIN_DIR/cocker-mcp"
  install -m 644 "$MAN_SRC"/*.1 "$MAN_DIR/"
  ok "Binaires + man pages installés ($MAN_DIR)"
else
  # Mode dev : pour que `cocker-dev` parle au bon daemon (socket dans
  # la data dir alternative), on ne peut pas juste installer le binaire
  # — il regarderait le socket prod par défaut. On installe le vrai
  # binaire dans libexec et un wrapper qui injecte COCKER_HOST dans
  # BIN_DIR. cockerd-dev et cocker-portfwd-dev sont des vrais binaires
  # directement (le daemon prend --root/--socket en args via le plist,
  # cocker-portfwd est invoqué par cockerd avec ses propres args).
  mkdir -p "$LIBEXEC_DIR"
  install -m 755 .build/release/cocker     "$LIBEXEC_DIR/cocker"
  install -m 755 .build/release/cocker-mcp "$LIBEXEC_DIR/cocker-mcp"
  install -m 755 .build/release/cockerd        "$BIN_DIR/cockerd$SUFFIX"
  install -m 755 .build/release/cocker-portfwd "$BIN_DIR/cocker-portfwd$SUFFIX"

  # Wrapper CLI : exporte COCKER_HOST pour que IPCClient.defaultSocketPath
  # trouve le socket dev, COCKER_DAEMON_BIN pour que `daemon start` lance
  # le bon cockerd-dev (sinon BinaryResolver retombe sur le brew prod),
  # puis exec le vrai binaire.
  cat > "$BIN_DIR/cocker$SUFFIX" <<WRAPPER
#!/bin/bash
# Auto-generated by cocker install.sh (SUFFIX=$SUFFIX). Points the CLI
# at the cocker$SUFFIX daemon socket so it doesn't accidentally talk to
# the prod cockerd at ~/.cocker/cocker.sock, and at the dev daemon
# binary so `cocker$SUFFIX daemon start` doesn't fall through to the
# brew-installed /opt/homebrew/bin/cockerd.
export COCKER_HOST="unix://$COCKER_SOCKET"
export COCKER_DAEMON_BIN="$BIN_DIR/cockerd$SUFFIX"
exec "$LIBEXEC_DIR/cocker" "\$@"
WRAPPER
  chmod 755 "$BIN_DIR/cocker$SUFFIX"

  cat > "$BIN_DIR/cocker-mcp$SUFFIX" <<WRAPPER
#!/bin/bash
# Auto-generated by cocker install.sh (SUFFIX=$SUFFIX).
export COCKER_HOST="unix://$COCKER_SOCKET"
export COCKER_DAEMON_BIN="$BIN_DIR/cockerd$SUFFIX"
exec "$LIBEXEC_DIR/cocker-mcp" "\$@"
WRAPPER
  chmod 755 "$BIN_DIR/cocker-mcp$SUFFIX"

  # Man pages : skip en mode dev. Leur contenu référence le nom "cocker"
  # (pas "cocker-dev") et leur installation entrerait en conflit avec
  # celles de la prod.
  ok "Binaires installés (cocker$SUFFIX wrappers in $BIN_DIR, real bins in $LIBEXEC_DIR)"
  warn "Man pages skipped en mode dev — utilise \`man cocker\` pour la prod"
fi

# 7. Cocker data dir
info "Configuration $COCKER_ROOT..."
mkdir -p "$COCKER_ROOT/kernel"
[ -e "$COCKER_ROOT/kernel/vmlinuz" ] && rm -f "$COCKER_ROOT/kernel/vmlinuz"
ln -sf "$APPLE_CONTAINER_KERNEL" "$COCKER_ROOT/kernel/vmlinuz"
cp cocker-init/initrd.img "$COCKER_ROOT/kernel/initrd.img"
ok "Kernel et initrd configurés"

# 8. launchd plist (auto-start cockerd au boot)
info "Configuration launchd..."
PLIST="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
mkdir -p "$(dirname "$PLIST")"

# En mode dev, le plist passe --root et --socket explicitement pour que
# le daemon utilise la data dir alternative et ne collide pas avec le
# socket prod. En mode prod, on garde le comportement existant (defaults).
if [ -z "$SUFFIX" ]; then
  CD_ARGS="<string>$BIN_DIR/cockerd</string>"
else
  CD_ARGS="<string>$BIN_DIR/cockerd$SUFFIX</string>
    <string>--root</string><string>$COCKER_ROOT</string>
    <string>--socket</string><string>$COCKER_SOCKET</string>"
fi

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LAUNCHD_LABEL</string>
  <key>ProgramArguments</key><array>
    $CD_ARGS
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
ok "cockerd$SUFFIX démarré via launchd (label $LAUNCHD_LABEL, logs : $COCKER_ROOT/cockerd.log)"

sleep 1

# 9. Verify
echo
info "Vérification..."
if "$BIN_DIR/cocker$SUFFIX" version >/dev/null 2>&1; then
  "$BIN_DIR/cocker$SUFFIX" version
  ok "cocker$SUFFIX fonctionne"
else
  warn "cocker$SUFFIX version a échoué — vérifie $COCKER_ROOT/cockerd.log"
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

# 11. Lease pool auto-clean helper (one-time root install).
# Skip en mode dev : c'est un LaunchDaemon system-wide qui sert tous
# les daemons cocker simultanés (helper unique, /var/db/dhcpd_leases est
# partagé par vmnet). Si la prod l'a déjà installé, le dev en profite.
HELPER_PLIST="/Library/LaunchDaemons/com.cocker.leases-helper.plist"
if [ -n "$SUFFIX" ]; then
  if [ -f "$HELPER_PLIST" ]; then
    ok "Lease helper system-wide déjà présent (installé par la prod)"
  else
    warn "Lease helper non installé. Run \`./install.sh\` (mode prod) une fois pour l'installer."
  fi
elif [ -f "$HELPER_PLIST" ]; then
  ok "Lease helper LaunchDaemon déjà installé"
else
  info "Installation du lease pool helper (sudo prompt unique)…"
  TMP_PLIST="$(mktemp)"
  cat > "$TMP_PLIST" <<'PLIST'
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
  if sudo install -m 644 -o root -g wheel "$TMP_PLIST" "$HELPER_PLIST" \
     && (sudo launchctl bootstrap system "$HELPER_PLIST" 2>/dev/null \
         || sudo launchctl load "$HELPER_PLIST"); then
    ok "Lease helper installé — plus de prompt sudo pour vider la pool"
  else
    warn "Lease helper non installé — utilise \`cocker daemon clear-leases\` si vmnet sature"
  fi
  rm -f "$TMP_PLIST"
fi

echo
color "1;32" "🎉 Cocker$SUFFIX installé. Essaye :"
echo "    cocker$SUFFIX pull alpine:latest"
echo "    cocker$SUFFIX run -d alpine:latest -- /bin/sh -c 'while true; do date; sleep 1; done'"
echo "    cocker$SUFFIX ps"
echo
echo "Pour stopper le daemon : launchctl bootout gui/$(id -u) $PLIST"
echo "Pour redémarrer        : launchctl kickstart -k gui/$(id -u)/$LAUNCHD_LABEL"
if [ -n "$SUFFIX" ]; then
  echo
  color "1;36" "Mode dev side-by-side actif :"
  echo "  - data dir   : $COCKER_ROOT"
  echo "  - socket     : $COCKER_SOCKET"
  echo "  - launchd    : $LAUNCHD_LABEL"
  echo "  - container$SUFFIX, images, volumes — isolés de la prod (\`cocker\`)"
  echo "  - les deux daemons cohabitent : \`cocker ps\` ≠ \`cocker$SUFFIX ps\`"
fi
echo
echo "MCP (Claude Desktop) — ajoute à ~/Library/Application Support/Claude/claude_desktop_config.json :"
echo '    { "mcpServers": { "cocker'"$SUFFIX"'": { "command": "'"$BIN_DIR/cocker-mcp$SUFFIX"'" } } }'
