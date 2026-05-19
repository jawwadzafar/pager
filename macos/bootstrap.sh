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
# PAGER_OS is consumed by lib/autostart.sh when we source it for --autostart.
# shellcheck disable=SC2034
PAGER_OS="mac"

# Flags
SKIP_AUTOSTART=0
for arg in "$@"; do
  case "$arg" in
    --no-autostart) SKIP_AUTOSTART=1 ;;
    --autostart)    SKIP_AUTOSTART=0 ;;   # explicit "yes" (default; kept for symmetry)
    -h|--help)
      cat <<USAGE
Usage: $0 [--no-autostart]

  Installs pager on macOS. By default, registers a LaunchAgent so the
  session comes back at every login (that's the "Claude Code that
  never sleeps" pitch — the reason pager exists). First login after
  install triggers a one-time stack of macOS TCC permission prompts;
  see macos/README.md for the safe-to-deny list.

  --no-autostart   skip LaunchAgent registration. pager only runs when
                   you type 'pager start'. No prompts. You can opt in
                   later with 'pager autostart enable'.
USAGE
      exit 0
      ;;
  esac
done

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

# 0. Soft claude check — pager isn't useful without it, but a missing
# claude binary often means "installed via npm but PATH not refreshed
# yet" rather than "user actually forgot." Warn and continue.
if ! command -v claude >/dev/null 2>&1; then
  warn "claude (Claude Code CLI) not found on PATH."
  warn "  Install: https://claude.com/code   (or: npm install -g @anthropic-ai/claude-code)"
  warn "  pager will install; you'll need claude before 'pager start' will work."
fi

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
# tmux:    persistent session for claude --remote-control
# libyaml: C parser used by pyyaml (faster CSafeLoader path)
#
# We deliberately do NOT install brew's python@X — Apple's CLT python3
# is fine for the inline json/yaml/datetime work bin/pager does, and
# Homebrew's `python` formulae don't always create the unversioned
# /opt/homebrew/bin/python3 symlink (real-Mac test in 0.4.0 showed
# bare `python3` resolving to /usr/bin/python3 anyway, making the brew
# python install ~75MB of dead weight).
log "2/11 brew install tmux libyaml"
brew install --quiet tmux libyaml
ok "tmux + libyaml installed"

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
#
# Important: bare `pip3` on a Mac may resolve to a pip older than 23.0.1 (no
# --break-system-packages flag) — e.g. from a previous python install. We
# always use `python3 -m pip` to bind to the python3 that bin/pager will
# actually invoke, and we cascade flags so old-pip systems still work.
log "4/11 pyyaml (Python inventory parser)"
PY3="$(command -v python3 || true)"
if [ -z "$PY3" ]; then
  echo "ERROR: no python3 on PATH after step 2 — brew python@3.13 install didn't take" >&2
  exit 1
fi
if python3 -c "import yaml" 2>/dev/null; then
  ok "pyyaml already importable ($PY3)"
elif python3 -m pip install --user --break-system-packages --quiet pyyaml 2>/dev/null; then
  ok "pyyaml installed via --break-system-packages ($PY3)"
elif python3 -m pip install --user --quiet pyyaml 2>/dev/null; then
  ok "pyyaml installed via plain --user ($PY3 — older pip, no PEP 668)"
else
  warn "pyyaml install failed via $PY3. Try manually:"
  warn "  $BREW_PREFIX/bin/python3.13 -m pip install --user --break-system-packages pyyaml"
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

# 7b. ~/.zshrc — pager .env auto-source.
# Writes the literal __PAGER_ROOT path so the line is correct regardless of
# where the user cloned the repo (~/pager, ~/.pager, anywhere).
touch "$HOME/.zshrc"
# Match any existing pager .env auto-source line, regardless of path.
if ! grep -qE 'pager/\.env' "$HOME/.zshrc" 2>/dev/null; then
  cat >> "$HOME/.zshrc" <<EOF

# pager: auto-load secrets from $__PAGER_ROOT/.env into every shell
[ -f "$__PAGER_ROOT/.env" ] && set -a && . "$__PAGER_ROOT/.env" && set +a
EOF
  # shellcheck disable=SC2088
  ok "Wrote ~/.zshrc auto-source line for $__PAGER_ROOT/.env"
else
  # shellcheck disable=SC2088
  ok "~/.zshrc already auto-sources a pager .env"
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

# 9b. Trust extra paths from PAGER_TRUST_PATHS (colon-separated, additive
# to $HOME). Read from .env earlier when the script sourced it via the
# usual pager-binary entry path. Bootstrap reads it directly here too.
if [ -n "${PAGER_TRUST_PATHS:-}" ]; then
  log "9b/11 trust extra paths"
  # Split on ':' the same way PATH does.
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

# 10. AUTOSTART (on by default; --no-autostart to skip) ----------------------
# Pager's whole pitch is "Claude Code that never sleeps" — autostart is
# how that works. So by default we register the LaunchAgent here. Users
# who explicitly don't want it can pass --no-autostart and opt in later
# via 'pager autostart enable'.
log "10/10 autostart"

autostart_was_enabled=0
if [ -f "$HOME/Library/LaunchAgents/com.pager.agent.plist" ]; then
  autostart_was_enabled=1
fi

if [ "$SKIP_AUTOSTART" -eq 1 ] && [ "$autostart_was_enabled" -ne 1 ]; then
  ok "autostart NOT registered (--no-autostart given). 'pager autostart enable' later to opt in."
else
  # Heads-up before triggering the macOS TCC prompt storm. Users see this
  # in the terminal scrollback alongside the prompts, so the dialogs are
  # less surprising. macos/README.md has the full safe-to-deny table.
  if [ "$autostart_was_enabled" -ne 1 ]; then
    warn "macOS will pop up a stack of permission prompts on first login."
    warn "  ALLOW:        'tmux would like to access data from other apps' (App Management)"
    warn "  DON'T ALLOW:  Full Disk Access, Music, Photos, Contacts, Documents — pager doesn't need any."
    warn "  See macos/README.md for the full table. Choices are remembered; you only see them once."
  fi
  # shellcheck source=../lib/autostart.sh
  # shellcheck disable=SC1091
  . "$__PAGER_ROOT/lib/autostart.sh"
  autostart_enable
fi

echo
echo "══════════════════════════════════════════════════════════════════"
echo "  DONE."
echo "  Open a new shell (or 'source ~/.zprofile && source ~/.zshrc')"
echo "  so PATH + env load, then run \`pager info\` any time to see this:"
echo "══════════════════════════════════════════════════════════════════"
# All the per-state details (currently trusted folders, autostart state,
# URL, command surface, doc pointers) — defer to `pager info` so the
# install-time banner stays in sync with the runtime command and we
# don't duplicate the formatting logic.
"$__PAGER_ROOT/bin/pager" info 2>&1 || true
echo "══════════════════════════════════════════════════════════════════"
echo "  Re-running ./macos/bootstrap.sh is safe — only does missing work."
echo "══════════════════════════════════════════════════════════════════"
