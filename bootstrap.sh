#!/usr/bin/env bash
# Idempotent rebuild of the pager on a fresh Linux box.
# Safe to re-run any time — only does work that's still missing.
#
# Prereq: this repo is cloned at ~/pager (or wherever this script lives).
# Usage:  ./bootstrap.sh
set -euo pipefail

__PAGER_ROOT="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="${USER:-$(whoami)}"

# --- ensure ~/pager/.env exists FIRST (sudo helper needs it) -------------------
if [ ! -f "$__PAGER_ROOT/.env" ]; then
  cp "$__PAGER_ROOT/.env.example" "$__PAGER_ROOT/.env"
  chmod 600 "$__PAGER_ROOT/.env"
  _CREATED_ENV=1
fi

# --- sudo helper -------------------------------------------------------------
# Sources pager lib/sudo.sh; if SUDO_PASSWORD is set in ~/pager/.env, sudo -A
# becomes non-interactive. Otherwise it falls back to interactive sudo.
PAGER_ROOT="$__PAGER_ROOT"
# shellcheck source=lib/sudo.sh
source "$__PAGER_ROOT/lib/sudo.sh"
SUDO="sudo"
[ -n "${SUDO_ASKPASS:-}" ] && SUDO="sudo -A"

log()  { printf "\n\033[1;36m==>\033[0m %s\n" "$*"; }
ok()   { printf "    \033[32m✓\033[0m %s\n" "$*"; }
warn() { printf "    \033[33m!\033[0m %s\n" "$*"; }

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
# shellcheck disable=SC2016  # intentional literal $ in regex
if ! grep -qE '\.\s+"\$HOME/pager/\.env"|\.\s+"\$PAGER_ROOT/\.env"' "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" <<'EOF'

# pager: auto-load secrets from ~/pager/.env into every shell
[ -f "$HOME/pager/.env" ] && set -a && . "$HOME/pager/.env" && set +a
EOF
  # shellcheck disable=SC2088
  ok "Wrote ~/.bashrc auto-source line for ~/pager/.env"
else
  # shellcheck disable=SC2088
  ok "bashrc already auto-sources ~/pager/.env"
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

# 7. SYSTEMD USER UNITS (service + watchdog) ---------------------------------
log "7/10 systemd user units"
mkdir -p "$HOME/.config/systemd/user"
install -m 644 "$__PAGER_ROOT/systemd/pager.service"       "$HOME/.config/systemd/user/pager.service"
install -m 644 "$__PAGER_ROOT/systemd/pager-watch.service" "$HOME/.config/systemd/user/pager-watch.service"
install -m 644 "$__PAGER_ROOT/systemd/pager-watch.timer"   "$HOME/.config/systemd/user/pager-watch.timer"
systemctl --user daemon-reload
systemctl --user enable pager.service       >/dev/null 2>&1
systemctl --user enable pager-watch.timer   >/dev/null 2>&1
ok "pager.service + pager-watch.timer installed and enabled"

# 8. LINGER (boot-time autostart, no login needed) ----------------------------
log "8/10 boot-time autostart (linger)"
if [ "$(loginctl show-user "$USER_NAME" -p Linger 2>/dev/null | cut -d= -f2)" = "yes" ]; then
  ok "Linger already enabled"
else
  $SUDO loginctl enable-linger "$USER_NAME"
  ok "Linger enabled — services now start at boot"
fi

# 9. START THE SERVICE + WATCHDOG --------------------------------------------
log "9/10 start pager.service + pager-watch.timer"
if ! systemctl --user is-active --quiet pager.service; then
  systemctl --user start pager.service
elif [ "$TRUST_CHANGED" -eq 1 ]; then
  # Trust state changed; restart so the running session picks up new trust.
  systemctl --user restart pager.service
  ok "Restarted pager.service to apply new trust state"
fi
ok "pager.service active"
systemctl --user start pager-watch.timer >/dev/null 2>&1 || true
ok "pager-watch.timer started"
sleep 3

# 10. VERIFY ------------------------------------------------------------------
log "10/10 verify"
if tmux ls 2>/dev/null | grep -q .; then
  tmux ls
  ok "tmux session(s) running"
else
  warn "no tmux sessions yet — try 'pager status' in a few seconds"
fi

URL=""
if [ -x "$__PAGER_ROOT/bin/pager" ]; then
  URL=$("$__PAGER_ROOT/bin/pager" url 2>/dev/null | awk '{print $2}' | head -1 || true)
fi

cat <<EOF

──────────────────────────────────────────────────────────────────────
  DONE. What to do next:

  1. Open a new shell (or 'source ~/.bashrc') so PATH + env load.
  2. 'pager' to see every available tool.
  3. 'pager url' to print the phone-accessible URL.
  4. 'pager attach' to talk to the local session.

EOF

if [ -n "$URL" ]; then
  echo "  Right now on this box:"
  echo "    Remote Control URL: $URL"
  echo ""
fi

cat <<EOF
  Re-running this script is safe — it only does work that's missing.
──────────────────────────────────────────────────────────────────────
EOF
