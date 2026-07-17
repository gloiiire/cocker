#!/usr/bin/env bash
# bump-version.sh — single source of truth for cocker release version.
#
# Usage : ./scripts/bump-version.sh X.Y.Z
#
# Synchronises the version string across the three places it lives :
#   1. /VERSION                                  — root-level source of truth
#   2. Sources/CockerCore/IPC/Protocol.swift     — CockerVersion.version constant
#                                                  (consumed by ~20 sites in cli + daemon)
#   3. Formula/cocker.rb                         — version "X.Y.Z" + root_url + bottle sha256 placeholders
#
# After running this, the only remaining release steps are :
#   git commit -am "chore: bump to X.Y.Z"
#   git push  →  PR feat → dev → main
#   git tag vX.Y.Z + git push --tags
# The CI workflow (release.yml) re-validates the three places match before
# building binaries, so a stale edit can't reach the release pipeline.

set -euo pipefail

cd "$(dirname "$0")/.."

if [ $# -ne 1 ]; then
    echo "usage: $0 X.Y.Z" >&2
    exit 64
fi

new_version="$1"

# Strict semver gate — we only allow "X.Y.Z" or "X.Y.Z.N". A typo in the
# version string would otherwise cascade into 3 files and produce a tag
# that nobody can `brew upgrade` to.
if ! [[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "error: '$new_version' is not a valid version (expected X.Y.Z or X.Y.Z.N)" >&2
    exit 65
fi

# Inputs
protocol_file="Sources/CockerCore/IPC/Protocol.swift"
formula_file="Formula/cocker.rb"
version_file="VERSION"

# Sanity check — every target file must exist before we touch any of them.
for f in "$protocol_file" "$formula_file"; do
    if [ ! -f "$f" ]; then
        echo "error: missing $f — are you running from the repo root ?" >&2
        exit 66
    fi
done

# 1. VERSION file (create or overwrite — this IS the source of truth).
echo "$new_version" > "$version_file"

# 2. CockerVersion.version in Protocol.swift. The line we replace looks
# like : `public static let version = "0.7.0"`. Anchor on `let version =`
# so we don't accidentally hit unrelated `version` mentions in comments.
# Use a tmp file + mv for atomicity (avoids leaving the file in a
# half-edited state if sed dies mid-way).
tmp="$(mktemp)"
sed -E "s|(public static let version = )\"[^\"]+\"|\1\"${new_version}\"|" "$protocol_file" > "$tmp"
mv "$tmp" "$protocol_file"

# 3. Formula/cocker.rb : three substitutions on a single file.
#  a) version "X.Y.Z"
#  b) root_url "...releases/download/vX.Y.Z"
#  c) The bottle sha256 → reset to a single `all:` placeholder so the
#     Bottle workflow patches it with the real hash once the release is
#     up. One bottle covers every macOS (see below).
tmp="$(mktemp)"
sed -E \
    -e "s|^( *version )\"[^\"]+\"|\1\"${new_version}\"|" \
    -e "s|releases/download/v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?|releases/download/v${new_version}|g" \
    "$formula_file" > "$tmp"
mv "$tmp" "$formula_file"

# Reset the bottle sha256 to a SINGLE `all:` placeholder. The arm64
# binary is byte-identical across macOS versions, so one bottle tagged
# `all` matches every macOS (Sonoma, Tahoe, and any future release)
# without needing a per-OS symbol — the Bottle workflow patches the one
# placeholder with the real hash. Idempotent : collapses the legacy 3
# per-OS lines OR an already-`all` line down to the single placeholder.
tmp="$(mktemp)"
awk '
  /^  bottle do/ { inb=1 }
  inb && /^    sha256 cellar: :any_skip_relocation, (arm64_|all:)/ {
    if (!done) { print "    sha256 cellar: :any_skip_relocation, all:      \"REPLACE_BOTTLE_SHA256_ALL\""; done=1 }
    next
  }
  inb && /^  end/ { inb=0 }
  { print }
' "$formula_file" > "$tmp"
mv "$tmp" "$formula_file"

# Pretty diff summary so a human can sanity-check what changed without
# running `git diff` themselves.
echo ""
echo "Bumped cocker → ${new_version}"
echo "  /VERSION                                  →  ${new_version}"
echo "  Sources/CockerCore/IPC/Protocol.swift     →  version = \"${new_version}\""
echo "  Formula/cocker.rb                         →  version + root_url + REPLACE_BOTTLE_SHA256_ALL placeholder"
echo ""
echo "Next steps :"
echo "  git diff                                   # inspect"
echo "  git commit -am \"chore: bump to ${new_version}\""
echo "  git push                                   # PR feat → dev → main"
echo "  git tag v${new_version} && git push --tags # the Release workflow takes over from here"
