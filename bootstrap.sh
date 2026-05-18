#!/usr/bin/env bash
# pager — top-level bootstrap dispatcher.
#
# Detects OS and execs the platform-specific bootstrap. Exists for backwards
# compatibility with the old layout (Linux bootstrap was at the repo root in
# v0.1.0–v0.3.x). New entry points:
#
#   curl -fsSL https://raw.githubusercontent.com/jawwadzafar/pager/main/install.sh | sh
#                                  ← fresh install, no repo needed
#   ./install.sh                   ← from a fresh clone, clones to ~/.pager
#   ./linux/bootstrap.sh           ← from an existing checkout, Linux
#   ./macos/bootstrap.sh           ← from an existing checkout, macOS
#
# This shim continues to work — ./bootstrap.sh remains a valid entry point.
set -euo pipefail

__here="$(cd "$(dirname "$0")" && pwd)"

case "$(uname -s)" in
  Linux)  exec "$__here/linux/bootstrap.sh" "$@" ;;
  Darwin) exec "$__here/macos/bootstrap.sh" "$@" ;;
  *)      echo "ERROR: unsupported OS '$(uname -s)' — pager supports Linux and macOS." >&2
          exit 1 ;;
esac
