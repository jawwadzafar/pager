#!/usr/bin/env bash
# Idempotent rebuild of the pager on a fresh macOS box.
# Supports macOS Tahoe 26 + Sequoia 15, both arm64 (Apple Silicon) and x86_64 (Intel).
# Safe to re-run any time — only does work that's still missing.
#
# Prereq: this repo is cloned at ~/pager (or wherever the parent of this script lives).
# Usage:  ./macos/bootstrap.sh
set -euo pipefail

__PAGER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
USER_NAME="${USER:-$(whoami)}"
USER_UID="$(id -u)"

# --- platform guard ----------------------------------------------------------
if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: this is the macOS bootstrap. Linux users run ../bootstrap.sh" >&2
  exit 1
fi

# Apple Silicon → /opt/homebrew, Intel → /usr/local
case "$(uname -m)" in
  arm64)  BREW_PREFIX=/opt/homebrew ;;
  x86_64) BREW_PREFIX=/usr/local ;;
  *)      echo "ERROR: unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

# Note: unlike the Linux bootstrap, this script does NOT source lib/sudo.sh.
# The only step that needs root on macOS is the Homebrew installer, which
# manages its own sudo prompt internally — we cannot pass SUDO_ASKPASS to it.
# Every other step (brew install, pip --user, launchctl gui/$UID, ~/.zshrc)
# is user-scope.

log()  { printf "\n\033[1;36m==>\033[0m %s\n" "$*"; }
ok()   { printf "    \033[32m✓\033[0m %s\n" "$*"; }
warn() { printf "    \033[33m!\033[0m %s\n" "$*"; }

# 1. HOMEBREW -----------------------------------------------------------------
log "1/11 Homebrew"
if ! command -v brew >/dev/null 2>&1 && [ ! -x "$BREW_PREFIX/bin/brew" ]; then
  warn "Homebrew not found — installing. The installer will prompt for sudo."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
# Ensure brew is on PATH for the rest of this script even if shellenv hasn't been sourced.
eval "$("$BREW_PREFIX/bin/brew" shellenv)"
ok "Homebrew available at $BREW_PREFIX"

# 2. BREW PACKAGES ------------------------------------------------------------
log "2/11 brew install tmux libyaml python@3.13"
# Quiet outputs but surface real errors.
brew install --quiet tmux libyaml python@3.13
ok "tmux + libyaml + python@3.13 installed"

# 3. SSHPASS (optional, third-party tap, swallow failures) --------------------
log "3/11 sshpass (optional)"
if command -v sshpass >/dev/null 2>&1; then
  ok "sshpass already installed"
elif brew install --quiet hudochenkov/sshpass/sshpass 2>/dev/null; then
  ok "sshpass installed (hudochenkov tap)"
else
  warn "sshpass install skipped — tap unreachable or failed."
  warn "pager ssh with password_env: hosts will not work until you run:"
  warn "  brew install hudochenkov/sshpass/sshpass"
fi

# 4. PYYAML via pip --user --break-system-packages ----------------------------
# Homebrew's pyyaml formula was disabled 2024-10-06. PEP 668 blocks plain pip
# installs to system / Homebrew Python. --user --break-system-packages is the
# pragmatic path: pyyaml is a single small library with no transitive deps,
# and --user writes to ~/Library/Python/3.x/lib/python/site-packages (per-user,
# not system).
log "4/11 pyyaml (Python inventory parser)"
if python3 -c "import yaml" 2>/dev/null; then
  ok "pyyaml already importable"
else
  pip3 install --user --break-system-packages --quiet pyyaml
  if python3 -c "import yaml" 2>/dev/null; then
    ok "pyyaml installed to user site-packages"
  else
    warn "pyyaml installed but not importable — check 'python3 -m site --user-site' is on sys.path"
  fi
fi

# 5. ~/pager/.env -------------------------------------------------------------
log "5/11 ~/pager/.env"
if [ ! -f "$__PAGER_ROOT/.env" ]; then
  cp "$__PAGER_ROOT/.env.example" "$__PAGER_ROOT/.env"
  chmod 600 "$__PAGER_ROOT/.env"
  # shellcheck disable=SC2088
  warn "Created ~/pager/.env from template — edit it and add real GH_TOKEN, *_SSH_PASS, etc."
else
  chmod 600 "$__PAGER_ROOT/.env"
  # shellcheck disable=SC2088
  ok "~/pager/.env already present (perms set to 600)"
fi

# 6. Install binary into ~/.local/bin ----------------------------------------
log "6/11 install pager binary"
mkdir -p "$HOME/.local/bin"
ln -sf "$__PAGER_ROOT/bin/pager" "$HOME/.local/bin/pager"
ok "Symlinked ~/.local/bin/pager → $__PAGER_ROOT/bin/pager"

# 7. zsh shell wiring ---------------------------------------------------------
# macOS default shell is zsh. Two files:
#   ~/.zprofile — login shells; right place for PATH (after path_helper).
#   ~/.zshrc    — interactive shells; right place for .env auto-source.
log "7/11 zsh shell wiring"

# 7a. ~/.zprofile — brew shellenv + ~/.local/bin
touch "$HOME/.zprofile"
# shellcheck disable=SC2016  # intentional literal $ in grep regex
if ! grep -qE 'brew shellenv' "$HOME/.zprofile" 2>/dev/null; then
  cat >> "$HOME/.zprofile" <<EOF

# pager: Homebrew env (added by macos/bootstrap.sh)
eval "\$($BREW_PREFIX/bin/brew shellenv)"
EOF
  # shellcheck disable=SC2088
  ok "Wrote ~/.zprofile brew shellenv line"
else
  # shellcheck disable=SC2088
  ok "~/.zprofile already runs brew shellenv"
fi

# shellcheck disable=SC2016
if ! grep -qE '\.local/bin' "$HOME/.zprofile" 2>/dev/null; then
  cat >> "$HOME/.zprofile" <<'EOF'

# pager: put ~/.local/bin on PATH (added by macos/bootstrap.sh)
[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"
EOF
  # shellcheck disable=SC2088
  ok "Wrote ~/.zprofile ~/.local/bin prepend"
else
  # shellcheck disable=SC2088
  ok "~/.zprofile already prepends ~/.local/bin"
fi

# 7b. ~/.zshrc — pager .env auto-source
touch "$HOME/.zshrc"
# shellcheck disable=SC2016
if ! grep -qE '\.\s+"\$HOME/pager/\.env"|\.\s+"\$PAGER_ROOT/\.env"' "$HOME/.zshrc" 2>/dev/null; then
  cat >> "$HOME/.zshrc" <<'EOF'

# pager: auto-load secrets from ~/pager/.env into every shell
[ -f "$HOME/pager/.env" ] && set -a && . "$HOME/pager/.env" && set +a
EOF
  # shellcheck disable=SC2088
  ok "Wrote ~/.zshrc auto-source line for ~/pager/.env"
else
  # shellcheck disable=SC2088
  ok "~/.zshrc already auto-sources ~/pager/.env"
fi

# 8. SSH key ------------------------------------------------------------------
log "8/11 SSH key"
if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
  # shellcheck disable=SC2088
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

# 9. CLAUDE CODE TRUST --------------------------------------------------------
# Step 10 always does bootout+bootstrap, so any trust state change is picked up
# automatically — no separate "restart if changed" branch needed (unlike the
# Linux bootstrap which gates restart on this).
log "9/11 Claude Code workspace trust"
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
sys.exit(0 if prev_trust else 10)
PYEOF
then
  # shellcheck disable=SC2088
  ok "~/.claude.json already trusts \$HOME"
else
  rc=$?
  if [ $rc -eq 10 ]; then
    # shellcheck disable=SC2088
    ok "Pre-trusted \$HOME in ~/.claude.json (autostart won't hit the trust prompt)"
  else
    warn "Couldn't update ~/.claude.json (python failed rc=$rc) — autostart may block on trust prompt"
  fi
fi

# 10. LAUNCHAGENTS (session + watchdog) ---------------------------------------
log "10/11 LaunchAgents (session + watchdog)"
mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$__PAGER_ROOT/logs"

# Render the templates with absolute paths substituted in.
# launchd plists don't expand $HOME or ~; they need literal absolute paths.
render_plist() {
  local src="$1" dst="$2"
  sed \
    -e "s|__USER_HOME__|$HOME|g" \
    -e "s|__BREW_BIN__|$BREW_PREFIX/bin|g" \
    "$src" > "$dst"
  chmod 644 "$dst"
}

render_plist \
  "$__PAGER_ROOT/macos/launchd/com.pager.session.plist.template" \
  "$HOME/Library/LaunchAgents/com.pager.session.plist"
ok "Rendered com.pager.session.plist"

render_plist \
  "$__PAGER_ROOT/macos/launchd/com.pager.watch.plist.template" \
  "$HOME/Library/LaunchAgents/com.pager.watch.plist"
ok "Rendered com.pager.watch.plist"

# Reload: bootout (ignore "not loaded") + bootstrap. This is the modern,
# non-deprecated launchctl 2.0 syntax.
launchctl bootout "gui/$USER_UID/com.pager.session" 2>/dev/null || true
launchctl bootstrap "gui/$USER_UID" "$HOME/Library/LaunchAgents/com.pager.session.plist"
ok "com.pager.session loaded"

launchctl bootout "gui/$USER_UID/com.pager.watch" 2>/dev/null || true
launchctl bootstrap "gui/$USER_UID" "$HOME/Library/LaunchAgents/com.pager.watch.plist"
ok "com.pager.watch loaded"

# Brief settle before verify.
sleep 3

# 11. VERIFY ------------------------------------------------------------------
log "11/11 verify"
if launchctl print "gui/$USER_UID/com.pager.session" >/dev/null 2>&1; then
  ok "com.pager.session registered with launchd"
else
  warn "com.pager.session not visible to launchctl — check ~/pager/logs/launchd-session.err"
fi

if tmux ls 2>/dev/null | grep -q .; then
  tmux ls
  ok "tmux session(s) running"
else
  warn "no tmux sessions yet — try 'pager status' in a few seconds, or check launchd-session.err"
fi

URL=""
if [ -x "$__PAGER_ROOT/bin/pager" ]; then
  URL=$("$__PAGER_ROOT/bin/pager" url 2>/dev/null | awk '{print $2}' | head -1 || true)
fi

cat <<EOF

──────────────────────────────────────────────────────────────────────
  DONE. What to do next:

  1. Open a new shell (or 'source ~/.zprofile && source ~/.zshrc') so
     PATH + env load.
  2. 'pager' to see every available tool.
  3. 'pager url' to print the phone-accessible URL.
  4. 'pager attach' to talk to the local session.

EOF

if [ -n "$URL" ]; then
  echo "  Right now on this box:"
  echo "    Remote Control URL: $URL"
  echo ""
fi

cat <<'EOF'
  Notes for macOS:
    • Autostart is at LOGIN, not boot (LaunchAgent semantics). For boot-
      time start without a login, enable auto-login in System Settings →
      Users & Groups (incompatible with FileVault). Linux's linger is not
      available on macOS without a LaunchDaemon (out of scope, phase 3).
    • 'pager doctor' and 'pager status' are OS-aware on this branch —
      doctor checks the LaunchAgents via launchctl; status is purely
      tmux-based. No systemctl noise on macOS.
    • Uninstall:
        launchctl bootout gui/$(id -u)/com.pager.session
        launchctl bootout gui/$(id -u)/com.pager.watch
        rm ~/Library/LaunchAgents/com.pager.{session,watch}.plist

  Re-running this script is safe — it only does work that's missing.
──────────────────────────────────────────────────────────────────────
EOF
