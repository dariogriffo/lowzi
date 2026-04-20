#!/usr/bin/env bash
# install-zlint.sh — Pinned installer for zlint (https://github.com/DonIsaac/zlint)
#
# What this does:
#   Downloads and runs the upstream zlint installer script, but pins it to a
#   specific release tag so all developers and CI use the same binary version.
#   The installer places the `zlint` binary in ~/.local/bin (Linux) or
#   ~/bin (macOS), which should be on your PATH.
#
# How to bump the version:
#   1. Check https://github.com/DonIsaac/zlint/releases for the latest tag.
#   2. Update ZLINT_VERSION below to the new tag (keep the "v" prefix).
#   3. Open a PR with just that one-line change and the PR title
#      "chore: bump zlint to <new version>".
#
# Usage:
#   bash tasks/install-zlint.sh
#
# After install, verify with:
#   zlint --version

set -euo pipefail

ZLINT_VERSION="v0.7.9"

echo "Installing zlint ${ZLINT_VERSION}..."

ZLINT_VERSION="${ZLINT_VERSION}" \
    curl -fsSL https://raw.githubusercontent.com/DonIsaac/zlint/refs/heads/main/tasks/install.sh | bash

echo "Done. Run 'zlint --version' to confirm."
