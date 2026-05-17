#!/usr/bin/env bash
# Shared sudo askpass helper for pager scripts.
#
# Usage from a script in bin/:
#   __PAGER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
#   source "$__PAGER_ROOT/lib/sudo.sh"
#   sudo -A apt-get update
#
# Behavior:
#   - Reads $PAGER_ROOT/.env for `SUDO_PASSWORD=...` (no `export` prefix on
#     that line, or with — both work).
#   - If found, writes a temp helper (chmod 700) that emits the password
#     to sudo and exports SUDO_ASKPASS so `sudo -A` runs without prompting.
#   - Cleans up the temp helper on shell EXIT.
#   - If SUDO_PASSWORD is not set, leaves SUDO_ASKPASS unset and sudo will
#     prompt the user interactively. Both modes work — the script just
#     needs to use `sudo -A` and the right thing happens.
#
# Security:
#   - The password value is NEVER echoed, logged, or printed to chat.
#   - Use boolean checks like `[ -n "$SUDO_PASSWORD" ]` if you need to
#     verify the value is present.
#   - The .env file lives at $PAGER_ROOT/.env (gitignored) with chmod 600.

# Locate $PAGER_ROOT: prefer env override, else derive from this file's location.
__PAGER_ROOT_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAGER_ROOT="${PAGER_ROOT:-$__PAGER_ROOT_DEFAULT}"
__SUDO_ENV_FILE="$PAGER_ROOT/.env"

if [ -r "$__SUDO_ENV_FILE" ] && grep -qE '^(export[[:space:]]+)?SUDO_PASSWORD=' "$__SUDO_ENV_FILE"; then
  __SUDO_ASKPASS_HELPER="$(mktemp)"
  cat > "$__SUDO_ASKPASS_HELPER" <<HELPER
#!/bin/bash
awk -F= '/^(export[[:space:]]+)?SUDO_PASSWORD=/{
  sub(/^(export[[:space:]]+)?SUDO_PASSWORD=/, "");
  gsub(/^"|"$|^'\''|'\''$/, "");
  print; exit
}' "$__SUDO_ENV_FILE"
HELPER
  chmod 700 "$__SUDO_ASKPASS_HELPER"
  export SUDO_ASKPASS="$__SUDO_ASKPASS_HELPER"
  trap 'rm -f "$__SUDO_ASKPASS_HELPER"' EXIT
fi

unset __PAGER_ROOT_DEFAULT
