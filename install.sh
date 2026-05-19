#!/bin/sh
# pager installer -- one-line install for Linux + macOS.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/jawwadzafar/pager/main/install.sh | sh
#
# Or from a fresh clone:
#   ./install.sh
#
# Env overrides:
#   PAGER_HOME    -- where to clone the repo (default: ~/.pager)
#   PAGER_BRANCH  -- branch / tag / sha to checkout (default: main)
#                   pin to a release: PAGER_BRANCH=v0.4.1 ...
#   PAGER_REPO    -- git URL (default: https://github.com/jawwadzafar/pager.git)
#
# POSIX sh-compatible -- runs cleanly under bash, dash, ash, zsh's sh.
set -eu

REPO="${PAGER_REPO:-https://github.com/jawwadzafar/pager.git}"
BRANCH="${PAGER_BRANCH:-main}"
TARGET="${PAGER_HOME:-$HOME/.pager}"

# -- colors (terminal only; POSIX-friendly -- no $'\033' bashism) --
if [ -t 1 ]; then
  esc=$(printf '\033')
  c_cyan="${esc}[1;36m"
  c_green="${esc}[32m"
  c_yellow="${esc}[33m"
  c_red="${esc}[31m"
  c_dim="${esc}[2m"
  c_reset="${esc}[0m"
else
  c_cyan=''; c_green=''; c_yellow=''; c_red=''; c_dim=''; c_reset=''
fi
log()  { printf '\n%s==>%s %s\n' "$c_cyan" "$c_reset" "$*"; }
ok()   { printf '    %sOK%s %s\n' "$c_green" "$c_reset" "$*"; }
warn() { printf '    %s!%s %s\n' "$c_yellow" "$c_reset" "$*" >&2; }
err()  { printf '    %sERROR:%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }

# -- OS detection --
case "$(uname -s)" in
  Linux)  OS=linux ;;
  Darwin) OS=mac ;;
  *) err "unsupported OS '$(uname -s)' -- pager supports Linux and macOS." ;;
esac

log "pager installer  ${c_dim}(os: $OS, target: $TARGET, branch: $BRANCH)${c_reset}"

# -- preflight: tell the user what's about to happen --
# This runs BEFORE clone / package install / autostart registration so users
# know what they're signing up for and how to opt out. macOS gets a bigger
# warning because of the first-login TCC permission storm.
cat <<EOF

  ${c_cyan}About to install pager. Here's what happens:${c_reset}

    1. Clone the pager repo into ${c_cyan}$TARGET${c_reset}
EOF
if [ "$OS" = mac ]; then
  cat <<EOF
    2. Install Homebrew (if missing -- prompts for your Mac password once)
    3. Install ${c_cyan}tmux libyaml${c_reset} via brew; ${c_cyan}pyyaml${c_reset} via pip --user
    4. Wire ${c_cyan}~/.zprofile${c_reset} + ${c_cyan}~/.zshrc${c_reset}
    5. Pre-trust ${c_cyan}\$HOME${c_reset} in ${c_cyan}~/.claude.json${c_reset} so claude won't show its trust dialog
    6. Register a LaunchAgent so pager comes back at every login

  ${c_yellow}!! At first login after install, macOS will pop up TCC prompts. !!${c_reset}
     The ONLY one you need to ${c_green}Allow${c_reset} is:
        ${c_cyan}"tmux" would like to access data from other apps${c_reset}   ${c_dim}(App Management)${c_reset}
     ${c_yellow}Deny${c_reset} the rest -- pager doesn't need any of them:
        Full Disk Access, Music, Photos, Contacts, Documents, Downloads, Desktop
     Choices are remembered. Subsequent logins are quiet.

  Don't want autostart at all? Re-run with ${c_cyan}--no-autostart${c_reset}:
        ${c_dim}curl -fsSL https://raw.githubusercontent.com/jawwadzafar/pager/main/install.sh | sh -s -- --no-autostart${c_reset}
EOF
else
  cat <<EOF
    2. Install ${c_cyan}tmux sshpass python3-yaml openssh-client${c_reset} via apt
    3. Wire ${c_cyan}~/.bashrc${c_reset}
    4. Pre-trust ${c_cyan}\$HOME${c_reset} in ${c_cyan}~/.claude.json${c_reset} so claude won't show its trust dialog
    5. Register systemd --user units so pager comes back at login

  ${c_dim}For boot-time start before any login, separately run after install:${c_reset}
        ${c_cyan}sudo loginctl enable-linger \$USER${c_reset}

  Don't want autostart at all? Re-run with ${c_cyan}--no-autostart${c_reset}:
        ${c_dim}curl -fsSL https://raw.githubusercontent.com/jawwadzafar/pager/main/install.sh | sh -s -- --no-autostart${c_reset}
EOF
fi
cat <<EOF

  After install, run ${c_cyan}pager info${c_reset} any time to see state + commands.

  ${c_dim}About ~/.pager/.env (created from template at install time, optional):${c_reset}
    ${c_dim}Holds optional config -- GH_TOKEN, SSH passwords for inventory hosts,${c_reset}
    ${c_dim}PAGER_TRUST_PATHS for extra trusted dirs, etc. The basic claude-on-rig${c_reset}
    ${c_dim}flow works without touching it. See ~/.pager/.env.example for the${c_reset}
    ${c_dim}full list of variables and what each does.${c_reset}

  ${c_dim}To pre-trust extra project dirs (so claude doesn't show its trust dialog):${c_reset}
    ${c_dim}pager trust ~/code ~/projects        # one-off${c_reset}
    ${c_dim}PAGER_TRUST_PATHS in ~/.pager/.env    # persistent across re-bootstraps${c_reset}
    ${c_dim}pager start --cwd ~/code/myproject   # auto-trust + start there${c_reset}

EOF

# -- git is required --
if ! command -v git >/dev/null 2>&1; then
  if [ "$OS" = mac ]; then
    err "git not found. Run:  xcode-select --install   then re-run this installer."
  else
    err "git not found. Install it first, e.g.:  sudo apt-get install -y git"
  fi
fi

# -- claude is needed for pager to actually be useful, but we don't hard-fail --
# It might be installed but not on PATH yet (e.g. just-installed-via-npm and
# PATH not refreshed). Warn loudly and continue.
if ! command -v claude >/dev/null 2>&1; then
  warn "claude (Claude Code CLI) not found on PATH."
  warn "  Install: https://claude.com/code   (or: npm install -g @anthropic-ai/claude-code)"
  warn "  pager will install; you'll need claude before 'pager start' will work."
fi

# -- clone or update --
if [ -d "$TARGET/.git" ]; then
  log "Existing clone at $TARGET -- fetching latest..."
  git -C "$TARGET" remote set-url origin "$REPO" 2>/dev/null || true
  git -C "$TARGET" fetch --quiet origin
  # Don't blow away local changes; just fast-forward.
  if ! git -C "$TARGET" checkout --quiet "$BRANCH" 2>/dev/null; then
    warn "couldn't checkout '$BRANCH' (local changes?). Leaving current branch in place."
  fi
  git -C "$TARGET" pull --ff-only --quiet || warn "pull --ff-only failed -- leaving repo as-is."
  ok "Updated $TARGET"
elif [ -e "$TARGET" ]; then
  err "$TARGET exists but isn't a git checkout. Move or remove it, then re-run."
else
  log "Cloning $REPO into $TARGET..."
  git clone --depth=1 --branch "$BRANCH" "$REPO" "$TARGET" >/dev/null
  ok "Cloned to $TARGET"
fi

# -- run platform bootstrap (pass through any flags the caller gave us) --
# Today the only flag we forward is --autostart (opt-in autostart registration).
log "Running $OS bootstrap (this is the longest step)..."
case "$OS" in
  linux) exec "$TARGET/linux/bootstrap.sh" "$@" ;;
  mac)   exec "$TARGET/macos/bootstrap.sh" "$@" ;;
esac
