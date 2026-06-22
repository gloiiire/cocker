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
#   git push  →  PR feat → dev → staging → main
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
#  c) The three sha256 lines for arm64_tahoe / sequoia / sonoma → reset to
#     placeholders so the Bottle workflow patches them with the real hash
#     once the release is up. If the formula already carries the new
#     version's hashes (e.g. we're re-running bump for a patch on top of
#     an already-released bottle), we skip the reset.
tmp="$(mktemp)"
sed -E \
    -e "s|^( *version )\"[^\"]+\"|\1\"${new_version}\"|" \
    -e "s|releases/download/v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?|releases/download/v${new_version}|g" \
    "$formula_file" > "$tmp"
mv "$tmp" "$formula_file"

# Reset the bottle sha256s — only if the workflow would otherwise no-op.
# We replace any 64-hex string in an `arm64_<codename>:` line with the
# canonical placeholder for that codename.
tmp="$(mktemp)"
sed -E \
    -e "s|(arm64_tahoe: +)\"[0-9a-f]{64}\"|\1\"REPLACE_BOTTLE_SHA256_TAHOE\"|" \
    -e "s|(arm64_sequoia: +)\"[0-9a-f]{64}\"|\1\"REPLACE_BOTTLE_SHA256_SEQUOIA\"|" \
    -e "s|(arm64_sonoma: +)\"[0-9a-f]{64}\"|\1\"REPLACE_BOTTLE_SHA256_SONOMA\"|" \
    "$formula_file" > "$tmp"
mv "$tmp" "$formula_file"

# Pretty diff summary so a human can sanity-check what changed without
# running `git diff` themselves.
echo ""
echo "Bumped cocker → ${new_version}"
echo "  /VERSION                                  →  ${new_version}"
echo "  Sources/CockerCore/IPC/Protocol.swift     →  version = \"${new_version}\""
echo "  Formula/cocker.rb                         →  version + root_url + REPLACE_BOTTLE_SHA256_* placeholders"
echo ""
echo "Next steps :"
echo "  git diff                                   # inspect"
echo "  git commit -am \"chore: bump to ${new_version}\""
echo "  git push                                   # PR feat → dev → staging → main"
echo "  git tag v${new_version} && git push --tags # the Release workflow takes over from here"
