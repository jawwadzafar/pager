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

# 10. LAUNCHAGENT (single combined agent) ------------------------------------
# Earlier versions (0.2.0 – 0.2.2) installed two agents: com.pager.session
# and com.pager.watch. macOS lists each as a separate Login Items entry,
# which is noisy. From 0.2.3 onward we ship a single com.pager.agent that
# runs the watchdog periodically (its existing restart path handles the
# initial spawn too, so we don't lose anything). This block migrates any
# old two-agent install in place.
log "10/11 LaunchAgent (single combined agent)"
mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$__PAGER_ROOT/logs"

# 10a. Tear down the old two-agent layout if present (idempotent).
for old in com.pager.session com.pager.watch; do
  if [ -f "$HOME/Library/LaunchAgents/$old.plist" ]; then
    launchctl bootout "gui/$USER_UID/$old" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$old.plist"
    ok "Migrated away from $old (booted out + removed)"
  fi
done

# 10b. Render the combined agent template with absolute paths substituted in.
# launchd plists don't expand $HOME or ~; they need literal absolute paths.
render_plist() {
  local src="$1" dst="$2"
  sed \
    -e "s|__PAGER_ROOT__|$__PAGER_ROOT|g" \
    -e "s|__USER_HOME__|$HOME|g" \
    -e "s|__BREW_BIN__|$BREW_PREFIX/bin|g" \
    "$src" > "$dst"
  chmod 644 "$dst"
}

render_plist \
  "$__PAGER_ROOT/macos/launchd/com.pager.agent.plist.template" \
  "$HOME/Library/LaunchAgents/com.pager.agent.plist"
ok "Rendered com.pager.agent.plist"

# 10c. Make Login Items render the pager icon + display name.
#
# Three things have to be true for macOS to show our icon + "pager"
# label (instead of the generic exec icon + "Item from unidentified
# developer"):
#
#   1. The LaunchAgent plist has an AssociatedBundleIdentifiers key
#      (added in macOS Ventura 13) pointing at the bundle's
#      CFBundleIdentifier. Already in the template.
#   2. macOS LaunchServices has indexed a bundle with that ID. We
#      ensure that by symlinking the bundle into ~/Applications (a
#      standard scan location) and calling lsregister -f on it.
#   3. The bundle is "valid" enough for Gatekeeper. We ad-hoc
#      codesign it so it has a signature, which improves Gatekeeper
#      reliability on icon resolution.

# Ad-hoc codesign the bundle so Gatekeeper considers it valid.
# `-s -` means anonymous / ad-hoc signing (no Apple Developer ID needed).
# `--force` overwrites any prior signature; `--deep` propagates to nested
# code (we don't have any, but harmless). Errors are swallowed because
# missing codesign on some minimal CLT installs shouldn't break install.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$__PAGER_ROOT/macos/pager.app" 2>/dev/null || true
  ok "Ad-hoc codesigned pager.app"
fi

# Symlink the bundle into ~/Applications so LaunchServices indexes it.
# The actual bundle stays in the repo — symlink is purely for indexing.
APPS_DIR="$HOME/Applications"
mkdir -p "$APPS_DIR"
APP_LINK="$APPS_DIR/pager.app"
if [ -L "$APP_LINK" ] || [ -e "$APP_LINK" ]; then
  rm -f "$APP_LINK"
fi
ln -s "$__PAGER_ROOT/macos/pager.app" "$APP_LINK"
ok "Symlinked $APP_LINK -> $__PAGER_ROOT/macos/pager.app"

# Force LaunchServices to register the bundle (both via the symlink and
# the canonical path, since BTM lookup order is murky).
lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [ -x "$lsregister" ]; then
  "$lsregister" -f "$APP_LINK" 2>/dev/null || true
  "$lsregister" -f "$__PAGER_ROOT/macos/pager.app" 2>/dev/null || true
  ok "Registered pager.app with LaunchServices (symlink + canonical)"
fi

# 10d. Reload (bootout if loaded, then bootstrap). Modern launchctl 2 syntax.
# bootout removes the BTM Login Items entry that pointed at the previous
# plist; bootstrap creates a fresh entry that now includes
# AssociatedBundleIdentifiers, so BTM looks up the icon via the bundle.
launchctl bootout "gui/$USER_UID/com.pager.agent" 2>/dev/null || true
launchctl bootstrap "gui/$USER_UID" "$HOME/Library/LaunchAgents/com.pager.agent.plist"
ok "com.pager.agent loaded"

# If the Login Items panel STILL shows the generic icon after all of
# the above (some BTM caches survive bootout), the user can run
# `sfltool resetbtm` once to wipe the database and re-run this bootstrap.
# We don't run it automatically because it affects ALL Login Items.

# Brief settle before verify (first tick of the watchdog spawns the session).
sleep 3

# 11. VERIFY ------------------------------------------------------------------
log "11/11 verify"
if launchctl print "gui/$USER_UID/com.pager.agent" >/dev/null 2>&1; then
  ok "com.pager.agent registered with launchd"
else
  warn "com.pager.agent not visible to launchctl — check ~/pager/logs/launchd-agent.err"
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
        launchctl bootout gui/$(id -u)/com.pager.agent
        rm ~/Library/LaunchAgents/com.pager.agent.plist

  Re-running this script is safe — it only does work that's missing.
──────────────────────────────────────────────────────────────────────
EOF
