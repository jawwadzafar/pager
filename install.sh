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

# -- git is required --
if ! command -v git >/dev/null 2>&1; then
  if [ "$OS" = mac ]; then
    err "git not found. Run:  xcode-select --install   then re-run this installer."
  else
    err "git not found. Install it first, e.g.:  sudo apt-get install -y git"
  fi
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

# -- run platform bootstrap --
log "Running $OS bootstrap (this is the longest step)..."
case "$OS" in
  linux) exec "$TARGET/linux/bootstrap.sh" ;;
  mac)   exec "$TARGET/macos/bootstrap.sh" ;;
esac
