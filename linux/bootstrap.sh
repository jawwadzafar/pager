#!/usr/bin/env bash
# Idempotent rebuild of the pager on a fresh Linux box.
# Safe to re-run any time — only does work that's still missing.
#
# Prereq: this repo is cloned somewhere — typically ~/.pager — and this
# script lives at $PAGER_ROOT/linux/bootstrap.sh.
# Usage:  ./linux/bootstrap.sh
set -euo pipefail

# This script lives at $PAGER_ROOT/linux/bootstrap.sh — go up one level
# to find the repo root.
__PAGER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
USER_NAME="${USER:-$(whoami)}"
# PAGER_OS is consumed by lib/autostart.sh.
# shellcheck disable=SC2034
PAGER_OS="linux"

# Flags
SKIP_AUTOSTART=0
for arg in "$@"; do
  case "$arg" in
    --no-autostart) SKIP_AUTOSTART=1 ;;
    --autostart)    SKIP_AUTOSTART=0 ;;   # explicit "yes" (default; kept for symmetry)
    -h|--help)
      cat <<USAGE
Usage: $0 [--no-autostart]

  Installs pager on Linux. By default, registers systemd --user units
  (pager.service + pager-watch.timer) so the session comes back at
  login. That's the "Claude Code that never sleeps" pitch.

  --no-autostart   skip the systemd unit registration. pager only runs
                   when you type 'pager start'. Opt in later with
                   'pager autostart enable'.

  For boot-time start before any login, separately run:
      sudo loginctl enable-linger \$USER
USAGE
      exit 0
      ;;
  esac
done

# --- ensure ~/pager/.env exists FIRST (sudo helper needs it) -------------------
if [ ! -f "$__PAGER_ROOT/.env" ]; then
  cp "$__PAGER_ROOT/.env.example" "$__PAGER_ROOT/.env"
  chmod 600 "$__PAGER_ROOT/.env"
  _CREATED_ENV=1
fi

# --- sudo helper -------------------------------------------------------------
# Sources pager lib/sudo.sh; if SUDO_PASSWORD is set in ~/pager/.env, sudo -A
# becomes non-interactive. Otherwise it falls back to interactive sudo.
# lib/sudo.sh reads $PAGER_ROOT — export so the sourced script sees it.
# shellcheck disable=SC2034  # used by sourced lib/sudo.sh
PAGER_ROOT="$__PAGER_ROOT"
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/sudo.sh
source "$__PAGER_ROOT/lib/sudo.sh"
SUDO="sudo"
[ -n "${SUDO_ASKPASS:-}" ] && SUDO="sudo -A"

log()  { printf "\n\033[1;36m==>\033[0m %s\n" "$*"; }
ok()   { printf "    \033[32m✓\033[0m %s\n" "$*"; }
warn() { printf "    \033[33m!\033[0m %s\n" "$*"; }

# 0. Soft claude check — pager isn't useful without it, but a missing
# claude binary often means "installed via npm but PATH not refreshed
# yet" rather than "user actually forgot." Warn and continue.
if ! command -v claude >/dev/null 2>&1; then
  warn "claude (Claude Code CLI) not found on PATH."
  warn "  Install: https://claude.com/code   (or: npm install -g @anthropic-ai/claude-code)"
  warn "  pager will install; you'll need claude before 'pager start' will work."
fi

# 0b. Linux distro check — currently we support apt-based distros only.
# Detect other major package managers and fail clearly with a contribution
# invite rather than half-installing on a wrong-PM box.
if ! command -v apt-get >/dev/null 2>&1; then
  detected="unknown"
  for pm in dnf yum pacman zypper apk emerge xbps-install; do
    if command -v "$pm" >/dev/null 2>&1; then detected="$pm"; break; fi
  done
  case "$detected" in
    dnf|yum)            distro_hint="Fedora / RHEL / CentOS family" ;;
    pacman)             distro_hint="Arch / Manjaro" ;;
    zypper)             distro_hint="openSUSE" ;;
    apk)                distro_hint="Alpine" ;;
    emerge)             distro_hint="Gentoo" ;;
    xbps-install)       distro_hint="Void Linux" ;;
    *)                  distro_hint="(no recognized package manager)" ;;
  esac
  echo
  printf '\033[31mERROR:\033[0m pager currently supports apt-based Linux distros only.\n' >&2
  printf '       Debian, Ubuntu, Pop!_OS, Linux Mint, Raspberry Pi OS — those work.\n' >&2
  printf '       Detected: %s  (%s)\n' "$detected" "$distro_hint" >&2
  echo >&2
  printf 'Adding support for your distro is a tractable PR — see CONTRIBUTING.md.\n' >&2
  printf 'Touch points:\n' >&2
  printf '  - linux/bootstrap.sh step 1 (apt-get install ... -> your-pm install ...)\n' >&2
  printf '  - Package name mapping (python3-yaml -> python3-pyyaml on Fedora, etc.)\n' >&2
  echo >&2
  printf 'Workaround for now: install the deps manually\n' >&2
  printf '  (tmux sshpass python3-yaml openssh-client curl ca-certificates),\n' >&2
  # shellcheck disable=SC2016  # literal backticks intentional in user-facing message
  printf '  then run `make install` to symlink the pager binary into PATH.\n' >&2
  echo >&2
  printf 'Issue tracker: https://github.com/jawwadzafar/pager/issues\n' >&2
  exit 1
fi

# 1. APT PREREQUISITES --------------------------------------------------------
log "1/10 apt prerequisites"
$SUDO apt-get update -qq
$SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  git tmux sshpass python3-yaml openssh-client curl ca-certificates
ok "tmux, sshpass, python3-yaml, openssh-client installed"

# 2. ~/pager/.env ---------------------------------------------------------------
log "2/10 ~/pager/.env"
chmod 600 "$__PAGER_ROOT/.env"
if [ -n "${_CREATED_ENV:-}" ]; then
  # shellcheck disable=SC2088  # ~/ shown literally to the user
  warn "Created ~/pager/.env from template — edit it and add real GH_TOKEN, *_SSH_PASS, etc."
  warn "Optionally set SUDO_PASSWORD too, then re-run this script for fully unattended setup."
else
  # shellcheck disable=SC2088
  ok "~/pager/.env already present (perms set to 600)"
fi

# 3. Install binary into ~/.local/bin ----------------------------------------
# ~/.local/bin is on PATH for every interactive shell on Ubuntu (via
# ~/.profile) and comes BEFORE /usr/bin, so we beat /usr/bin/pager
# (the Debian "pager" alternative pointing at less). Symlink, so future
# `git pull`s in this repo are picked up automatically with no reinstall.
log "3/10 install pager binary"
mkdir -p "$HOME/.local/bin"
ln -sf "$__PAGER_ROOT/bin/pager" "$HOME/.local/bin/pager"
ok "Symlinked ~/.local/bin/pager → $__PAGER_ROOT/bin/pager"

# Verify the symlink wins over /usr/bin/pager. ~/.profile prepends
# ~/.local/bin if the dir exists at shell startup; on a fresh box where we
# just created the dir, current $PATH may not include it yet — that's fine,
# the next login picks it up. Just warn if we can detect a permanent shadow.
if [ -x /usr/bin/pager ] && [ -x "$HOME/.local/bin/pager" ]; then
  # Decide by looking at order in a freshly-loaded login PATH.
  LOGIN_PATH="$(bash -lc 'printf %s "$PATH"' 2>/dev/null || echo "$PATH")"
  # shellcheck disable=SC2088  # ~/.local/bin shown literally to user
  case ":$LOGIN_PATH:" in
    *":$HOME/.local/bin:"*":/usr/bin:"*) ok "~/.local/bin precedes /usr/bin on login PATH" ;;
    *":$HOME/.local/bin:"*)              ok "~/.local/bin on login PATH (no /usr/bin entry)" ;;
    *)                                   warn "~/.local/bin not on login PATH — pager may resolve to /usr/bin/pager (less alias)"
                                         warn "Fix: ensure ~/.profile contains the standard 'if [ -d \"\$HOME/.local/bin\" ]' block" ;;
  esac
fi

# 4. ~/.bashrc wiring ---------------------------------------------------------
# Only wire the .env auto-source. PATH is handled by the symlink above plus
# ~/.profile's standard ~/.local/bin block — no need to touch PATH in bashrc.
log "4/10 ~/.bashrc env wiring"
# Match any existing pager .env auto-source line, regardless of clone path.
# Writes the literal $__PAGER_ROOT so the line is correct whether the user
# cloned to ~/pager, ~/.pager, or anywhere else.
if ! grep -qE 'pager/\.env' "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" <<EOF

# pager: auto-load secrets from $__PAGER_ROOT/.env into every shell
[ -f "$__PAGER_ROOT/.env" ] && set -a && . "$__PAGER_ROOT/.env" && set +a
EOF
  # shellcheck disable=SC2088
  ok "Wrote ~/.bashrc auto-source line for $__PAGER_ROOT/.env"
else
  # shellcheck disable=SC2088
  ok "~/.bashrc already auto-sources a pager .env"
fi

# Clean up legacy PATH-prepend line from older bootstrap versions (was needed
# before we switched to the ~/.local/bin symlink). Idempotent: only removes
# if present, and saves a timestamped backup of ~/.bashrc first.
# shellcheck disable=SC2016  # intentional literal $HOME / $PATH in grep regex
if grep -qE '"\$HOME/pager/bin"|pager/bin:\$PATH' "$HOME/.bashrc" 2>/dev/null; then
  cp "$HOME/.bashrc" "$HOME/.bashrc.pager.bak.$(date +%Y%m%d%H%M%S)"
  awk '
    /^# pager: put bin\/ on PATH$/ { skip=2; next }
    skip > 0                       { skip--; next }
    { print }
  ' "$HOME/.bashrc" > "$HOME/.bashrc.pager.tmp" && mv "$HOME/.bashrc.pager.tmp" "$HOME/.bashrc"
  ok "Removed legacy PATH-prepend line from ~/.bashrc (backup saved)"
fi

# 5. SSH key ------------------------------------------------------------------
log "5/10 SSH key"
if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
  # shellcheck disable=SC2088  # ~/ literal in user-facing instructions
  warn "No ~/.ssh/id_ed25519. To create one without passphrase (recommended for headless flow):"
  warn "  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N '' -C \"$USER_NAME@$(hostname)\""
elif ssh-keygen -y -P "" -f "$HOME/.ssh/id_ed25519" >/dev/null 2>&1; then
  # shellcheck disable=SC2088
  ok "~/.ssh/id_ed25519 has no passphrase (ssh-add not needed)"
else
  # shellcheck disable=SC2088
  warn "~/.ssh/id_ed25519 has a passphrase. To remove (required for headless flow):"
  warn "  ssh-keygen -p -f ~/.ssh/id_ed25519 -N ''"
fi

# 6. CLAUDE CODE TRUST --------------------------------------------------------
# First-run Claude shows a "Trust this folder?" prompt on every new $HOME.
# Until confirmed, the session sits idle and never registers a Remote
# Control URL. Pre-set the trust flag in ~/.claude.json so the autostart
# session goes straight to the prompt and the URL appears immediately.
log "6/10 Claude Code workspace trust"
TRUST_CHANGED=0
if python3 - <<'PYEOF'
import json, os, sys
p = os.path.expanduser('~/.claude.json')
home = os.path.expanduser('~')
if os.path.exists(p):
    with open(p) as f: d = json.load(f)
else:
    d = {}
projects = d.setdefault('projects', {})
proj = projects.setdefault(home, {})
prev_trust = proj.get('hasTrustDialogAccepted', False)
proj['hasTrustDialogAccepted'] = True
proj['hasCompletedProjectOnboarding'] = True
with open(p, 'w') as f: json.dump(d, f, indent=2)
os.chmod(p, 0o600)
sys.exit(0 if prev_trust else 10)   # exit 10 if we just changed it
PYEOF
then
  # shellcheck disable=SC2088
  ok "~/.claude.json already trusts \$HOME"
else
  rc=$?
  if [ $rc -eq 10 ]; then
    TRUST_CHANGED=1
    # shellcheck disable=SC2088
    ok "Pre-trusted \$HOME in ~/.claude.json (autostart won't hit the trust prompt)"
  else
    warn "Couldn't update ~/.claude.json (python failed rc=$rc) — autostart may block on trust prompt"
  fi
fi

# 6b. Trust extra paths from PAGER_TRUST_PATHS (colon-separated, additive
# to $HOME). Sourced from .env at the top of this script.
if [ -n "${PAGER_TRUST_PATHS:-}" ]; then
  log "6b/8 trust extra paths"
  _IFS_SAVE="${IFS-}"
  IFS=:
  # shellcheck disable=SC2086  # intentional word-split on the env var
  set -- $PAGER_TRUST_PATHS
  IFS="$_IFS_SAVE"
  if [ -x "$__PAGER_ROOT/bin/pager" ]; then
    "$__PAGER_ROOT/bin/pager" trust "$@" 2>&1 | sed 's/^/    /' || warn "some PAGER_TRUST_PATHS entries failed"
  else
    warn "bin/pager not yet executable — skipped extra-path trust. Run \`pager trust\` after install."
  fi
fi

# 7. AUTOSTART (on by default; --no-autostart to skip) -----------------------
# Pager's pitch is "Claude Code that never sleeps" — autostart is what
# delivers that. Default registers the systemd --user units; pass
# --no-autostart to skip.
log "7/8 autostart"

autostart_was_enabled=0
if [ -f "$HOME/.config/systemd/user/pager.service" ]; then
  autostart_was_enabled=1
fi

if [ "$SKIP_AUTOSTART" -eq 1 ] && [ "$autostart_was_enabled" -ne 1 ]; then
  ok "autostart NOT registered (--no-autostart given). 'pager autostart enable' later to opt in."
else
  # shellcheck source=../lib/autostart.sh
  # shellcheck disable=SC1091
  . "$__PAGER_ROOT/lib/autostart.sh"
  autostart_enable
  # Apply trust-state-changed restart if applicable.
  if [ "${TRUST_CHANGED:-0}" -eq 1 ]; then
    systemctl --user restart pager.service 2>/dev/null || true
    ok "Restarted pager.service to apply new trust state"
  fi
  sleep 3
fi

# 8. VERIFY ------------------------------------------------------------------
log "8/8 verify"
if tmux ls 2>/dev/null | grep -q .; then
  tmux ls
  ok "tmux session(s) running"
else
  warn "no tmux sessions yet — run 'pager start' to spawn one"
fi

echo
echo "══════════════════════════════════════════════════════════════════"
echo "  DONE."
echo "  Open a new shell (or 'source ~/.bashrc') so PATH + env load,"
echo "  then run \`pager info\` any time to see this:"
echo "══════════════════════════════════════════════════════════════════"
# All state details (trusted folders, autostart, URL, command surface,
# doc pointers) defer to `pager info` so this banner stays in sync with
# the runtime command.
"$__PAGER_ROOT/bin/pager" info 2>&1 || true
echo "══════════════════════════════════════════════════════════════════"
echo "  Re-running ./linux/bootstrap.sh is safe — only does missing work."
echo "══════════════════════════════════════════════════════════════════"
