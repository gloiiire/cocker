# Verifying a cocker release

Every release tag (`v0.2.1` and later) is signed by GitHub Actions using **cosign keyless OIDC** and attested with **SLSA build provenance**. The signatures prove the binary was produced by this repo's CI pipeline, not by someone else.

## Prerequisites

```bash
brew install cosign gh
```

## Verify a binary signature

```bash
TAG=v0.2.1
gh release download "$TAG" --repo gloiiire/cocker --pattern '*'

# Verify cockerd
cosign verify-blob \
  --certificate=cockerd-${TAG}-arm64-macos.crt \
  --signature=cockerd-${TAG}-arm64-macos.sig \
  --certificate-identity-regexp='https://github.com/gloiiire/cocker/.*' \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
  cockerd-${TAG}-arm64-macos
```

You should see `Verified OK`. The certificate carries the repo URL and the workflow file that signed it (`release.yml`) — if either has been tampered with, verification fails.

## Verify SLSA provenance

```bash
gh attestation verify --owner gloiiire cockerd-${TAG}-arm64-macos
```

This checks that GitHub itself attests the binary came from the `release.yml` workflow on a specific commit of `main`.

## Verify checksums

```bash
shasum -a 256 -c SHA256SUMS
```

Should report `OK` for every file in the release.

## Why not GPG?

GPG keys have to be created, rotated, and revoked manually. Lose the private key and you lose the ability to issue signed releases. Cosign keyless mode uses short-lived certificates issued per workflow run via the Sigstore public Fulcio CA — there's nothing to lose or compromise, and Rekor (the public transparency log) records every signing event for audit.
