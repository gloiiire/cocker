#!/usr/bin/env bash
# Validation par mutation des tests de registre : on réintroduit chaque
# défaut corrigé et on exige que la suite passe au rouge.
set -u
cd "$(dirname "$0")/.." || exit 1
CIBLE="Sources/CockerCore/OCI/Registry.swift"
SAUVE="/tmp/Registry.original.swift"
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
t = open(chemin, encoding="utf-8").read()
if de not in t:
    sys.exit(9)
open(chemin, "w", encoding="utf-8").write(t.replace(de, vers, 1))
PY
    if [ $? -eq 9 ]; then
        echo "FAIL  mutation inapplicable (motif absent) : $nom"
        echecs=$((echecs + 1)); return
    fi
    if swift test --filter RegistryTokenScope >/tmp/mut-reg.log 2>&1; then
        echo "FAIL  passe inaperçu : $nom"
        echecs=$((echecs + 1))
    else
        echo "PASS  détecté : $nom"
    fi
}

# 1. Le bug d'origine : clé sans le dépôt, le jeton d'alpine sert à busybox.
muter "clé de cache sans le dépôt (jeton réutilisé, 401)" \
      '[registry, repository, scope]' \
      '[registry, scope]'

# 2. Collision par recollement des champs.
muter "champs concaténés sans préfixe de longueur (collision)" \
      '.map { "\($0.count):\($0)" }' \
      '.map { "\($0)" }'

# 3. Le message trompeur d'origine.
muter "401 de nouveau présenté comme « manifest not found »" \
      'return "not authorized (\(status)) — the registry refused the "
                + "token; run `cocker login` if the image is private"' \
      'return "Manifest not found"'

# 4. Limitation de débit sans marche à suivre.
muter "429 sans marche à suivre" \
      'return "rate limited by the registry (429) — wait, or "
                + "authenticate with `cocker login` for a higher quota"' \
      'return "rate limited (429)"'

# 5. Erreur serveur attribuée à l'image plutôt qu'au registre.
muter "5xx attribué à l'image au lieu du registre" \
      'return "registry error (\(status)) — this is on the registry "
                + "side, retrying usually works"' \
      'return "not found (\(status))"'

echo
if [ $echecs -eq 0 ]; then
    echo "Les 5 régressions sont détectées par la suite."
else
    echo "$echecs régression(s) passeraient inaperçues."
fi
exit $((echecs == 0 ? 0 : 1))
