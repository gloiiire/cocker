#!/usr/bin/env bash
# Validation par mutation des tests RunMountFlags.
#
# Un test qui ne tombe jamais ne prouve rien. On réintroduit chaque bug
# corrigé, un par un, et on exige que la suite passe au rouge.
#
# Usage : bash Tests/mutation-runmountflags.sh

set -u
cd "$(dirname "$0")/.." || exit 1
CIBLE="Sources/CockerDaemon/Engine/RunMountFlags.swift"
SAUVE="/tmp/RunMountFlags.original.swift"
cp "$CIBLE" "$SAUVE"
restaurer() { cp "$SAUVE" "$CIBLE"; }
trap restaurer EXIT

echecs=0

muter() {
    local nom="$1" de="$2" vers="$3"
    restaurer
    python3 - "$CIBLE" "$de" "$vers" <<'PY'
import sys
chemin, de, vers = sys.argv[1], sys.argv[2], sys.argv[3]
texte = open(chemin, encoding="utf-8").read()
if de not in texte:
    sys.exit(9)
open(chemin, "w", encoding="utf-8").write(texte.replace(de, vers, 1))
PY
    if [ $? -eq 9 ]; then
        echo "FAIL  mutation inapplicable (motif absent) : $nom"
        echecs=$((echecs + 1))
        return
    fi

    if swift test --filter RunMountFlags >/tmp/mut-run.log 2>&1; then
        echo "FAIL  passe inaperçu : $nom"
        echecs=$((echecs + 1))
    else
        echo "PASS  détecté : $nom"
    fi
}

# 1. Le bug d'origine : le flag part au shell.
muter "le flag --mount repart au shell" \
      'guard rest.hasPrefix("--mount") else { break }' \
      'guard false else { break }'

# 2. Casse du type : TYPE=CACHE retombait sur bind et cassait le build.
muter "type= comparé avec la casse (TYPE=CACHE casse le build)" \
      'parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "type"' \
      'parts[0].trimmingCharacters(in: .whitespaces) == "type"'

# 3. Préfixe non gardé : --security-opt consommé à tort.
muter "préfixe de flag non gardé (--security-opt avalé)" \
      'otherFlags.first(where: { isFlag($0, at: rest) })' \
      'otherFlags.first(where: { rest.hasPrefix($0) })'

# 4. bind traité comme ignorable : image fausse construite en silence.
muter "type=bind traité comme ignorable (image fausse)" \
      '["bind", "secret", "ssh"].contains(type)' \
      '["secret", "ssh"].contains(type)'

# 5. Message trompeur : parler de montage pour un flag réseau.
muter "avertissement réseau qui parle de montage" \
      'let flags = unique.filter { otherFlagNames.contains($0) }' \
      'let flags: [String] = []'

echo
if [ $echecs -eq 0 ]; then
    echo "Les 5 régressions sont détectées par la suite."
else
    echo "$echecs régression(s) passeraient inaperçues."
fi
exit $((echecs == 0 ? 0 : 1))
