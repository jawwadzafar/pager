#!/usr/bin/env bash
# Shared autostart-management functions for pager.
#
# Sourced by:
#   bin/pager          — backs the `pager autostart enable/disable/status` cmd
#   macos/bootstrap.sh — called when run with --autostart
#   linux/bootstrap.sh — called when run with --autostart
#
# Why this is a separate library:
#   In 0.6.0 we made autostart opt-in. The default install no longer
#   registers a LaunchAgent / systemd unit — users explicitly enable it
#   later with `pager autostart enable`. To support that, the
#   register-the-service logic moved out of the bootstrap scripts and
#   into here, so both the bootstrap (with --autostart) and the runtime
#   command can use the same code path.
#
# Dependencies (set by the caller before sourcing):
#   $__PAGER_ROOT  — repo root (absolute)
#   $PAGER_OS      — "mac" or "linux"
#   $BREW_PREFIX   — only on macOS; /opt/homebrew or /usr/local

# Guard: only source once.
if [ -n "${__PAGER_AUTOSTART_LOADED:-}" ]; then
  return 0
fi
__PAGER_AUTOSTART_LOADED=1

# Output helpers (these may already exist in the caller; redefine only if not).
if ! type ok >/dev/null 2>&1; then
  ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
fi
if ! type warn >/dev/null 2>&1; then
  warn() { printf '    \033[33m!\033[0m %s\n' "$*" >&2; }
fi

# ============================================================================
# Public entry points (called from bin/pager and the bootstraps)
# ============================================================================

# autostart_enable — install + register the autostart unit for the current OS.
# Idempotent: tears down any prior install first.
autostart_enable() {
  if [ "${PAGER_OS:-}" = "mac" ]; then
    _autostart_enable_mac
  else
    _autostart_enable_linux
  fi
}

# autostart_disable — remove the autostart unit for the current OS.
# Idempotent: warns and returns 0 if nothing was installed.
autostart_disable() {
  if [ "${PAGER_OS:-}" = "mac" ]; then
    _autostart_disable_mac
  else
    _autostart_disable_linux
  fi
}

# autostart_status — print whether autostart is currently registered.
# Returns 0 if enabled, 1 if disabled.
autostart_status() {
  if [ "${PAGER_OS:-}" = "mac" ]; then
    _autostart_status_mac
  else
    _autostart_status_linux
  fi
}

# ============================================================================
# macOS implementation
# ============================================================================

_autostart_enable_mac() {
  local user_uid
  user_uid="$(id -u)"
  local plist_dst="$HOME/Library/LaunchAgents/com.pager.agent.plist"
  local apps_dir="$HOME/Applications"
  local app_copy="$apps_dir/pager.app"

  # 1. Tear down any legacy two-agent install from pre-0.2.3.
  local legacy
  for legacy in com.pager.session com.pager.watch; do
    if [ -f "$HOME/Library/LaunchAgents/$legacy.plist" ]; then
      launchctl bootout "gui/$user_uid/$legacy" 2>/dev/null || true
      rm -f "$HOME/Library/LaunchAgents/$legacy.plist"
      ok "Migrated away from $legacy"
    fi
  done

  # 2. Render the LaunchAgent plist with absolute paths substituted.
  mkdir -p "$HOME/Library/LaunchAgents"
  mkdir -p "$__PAGER_ROOT/logs"
  sed \
    -e "s|__PAGER_ROOT__|$__PAGER_ROOT|g" \
    -e "s|__USER_HOME__|$HOME|g" \
    -e "s|__BREW_BIN__|${BREW_PREFIX:-/opt/homebrew}/bin|g" \
    "$__PAGER_ROOT/macos/launchd/com.pager.agent.plist.template" \
    > "$plist_dst"
  chmod 644 "$plist_dst"
  ok "Rendered com.pager.agent.plist"

  # 3. Copy the .app bundle into ~/Applications so LaunchServices can
  # index it (a symlink into a hidden dir won't work — Spotlight skips
  # paths inside dotfiles). The bundle contents are pure metadata; the
  # launcher inside exec's $PAGER_ROOT/bin/pager via env.
  mkdir -p "$apps_dir"
  rm -rf "$app_copy"
  cp -R "$__PAGER_ROOT/macos/pager.app" "$app_copy"
  ok "Copied pager.app -> $app_copy"

  # 4. Ad-hoc codesign the copy. Anonymous identity (`-s -`) needs no
  # Apple Developer ID. Improves Gatekeeper's bundle handling.
  if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$app_copy" 2>/dev/null || true
    ok "Ad-hoc codesigned $app_copy"
  fi

  # 5. Force LaunchServices to register the bundle.
  local lsregister
  lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
  if [ -x "$lsregister" ]; then
    "$lsregister" -f "$app_copy" 2>/dev/null || true
    ok "Registered $app_copy with LaunchServices"
  fi

  # 6. Reload via modern launchctl 2 syntax.
  launchctl bootout "gui/$user_uid/com.pager.agent" 2>/dev/null || true
  launchctl bootstrap "gui/$user_uid" "$plist_dst"
  ok "com.pager.agent loaded"

  printf '\n  %s\n' "Autostart enabled. The watchdog will fire every 70s from now until you run 'pager autostart disable'."
}

_autostart_disable_mac() {
  local user_uid
  user_uid="$(id -u)"
  local removed=0
  local label
  for label in com.pager.agent com.pager.session com.pager.watch; do
    if launchctl bootout "gui/$user_uid/$label" 2>/dev/null; then
      ok "Booted out $label"
      removed=1
    fi
    if [ -f "$HOME/Library/LaunchAgents/$label.plist" ]; then
      rm -f "$HOME/Library/LaunchAgents/$label.plist"
      ok "Removed ~/Library/LaunchAgents/$label.plist"
      removed=1
    fi
  done
  if [ -d "$HOME/Applications/pager.app" ] || [ -L "$HOME/Applications/pager.app" ]; then
    rm -rf "$HOME/Applications/pager.app"
    ok "Removed ~/Applications/pager.app"
    removed=1
  fi
  if [ "$removed" -eq 0 ]; then
    warn "Autostart was not enabled — nothing to remove."
    return 0
  fi
  printf '\n  %s\n' "Autostart disabled. pager will no longer launch at login. Use 'pager start' to spawn a session on demand."
}

_autostart_status_mac() {
  local user_uid
  user_uid="$(id -u)"
  local plist="$HOME/Library/LaunchAgents/com.pager.agent.plist"
  if [ ! -f "$plist" ]; then
    printf '  autostart: \033[33mdisabled\033[0m (no plist at %s)\n' "$plist"
    return 1
  fi
  if launchctl print "gui/$user_uid/com.pager.agent" >/dev/null 2>&1; then
    printf '  autostart: \033[32menabled\033[0m (com.pager.agent loaded in gui/%s)\n' "$user_uid"
    return 0
  else
    # shellcheck disable=SC2016  # backticks intentional in the message
    printf '  autostart: \033[33mplist present but not loaded\033[0m -- try `pager autostart enable` to re-register\n'
    return 1
  fi
}

# ============================================================================
# Linux implementation
# ============================================================================

_autostart_enable_linux() {
  local sysd_user="$HOME/.config/systemd/user"
  mkdir -p "$sysd_user"

  # Render the unit templates with __PAGER_ROOT__ substituted.
  local unit
  for unit in pager.service pager-watch.service pager-watch.timer; do
    sed -e "s|__PAGER_ROOT__|$__PAGER_ROOT|g" \
      "$__PAGER_ROOT/linux/systemd/$unit" \
      > "$sysd_user/$unit"
    chmod 644 "$sysd_user/$unit"
  done
  ok "Installed systemd user units (pager.service + pager-watch.timer)"

  systemctl --user daemon-reload
  systemctl --user enable pager.service     >/dev/null 2>&1 || true
  systemctl --user enable pager-watch.timer >/dev/null 2>&1 || true
  ok "Units enabled"

  systemctl --user start pager.service       2>/dev/null || true
  systemctl --user start pager-watch.timer   2>/dev/null || true
  ok "Service + timer started"

  printf '\n  %s\n' "Autostart enabled. pager.service will start at next login."
  printf '  %s\n'   "For boot-time start (before any login), enable linger manually:"
  printf '  %s\n'   "      sudo loginctl enable-linger \$USER"
}

_autostart_disable_linux() {
  local removed=0
  local sysd_user="$HOME/.config/systemd/user"
  local unit
  for unit in pager-watch.timer pager-watch.service pager.service; do
    if systemctl --user is-enabled "$unit" >/dev/null 2>&1 || \
       systemctl --user is-active  "$unit" >/dev/null 2>&1; then
      systemctl --user stop    "$unit" 2>/dev/null || true
      systemctl --user disable "$unit" 2>/dev/null || true
      ok "Stopped + disabled $unit"
      removed=1
    fi
    if [ -f "$sysd_user/$unit" ]; then
      rm -f "$sysd_user/$unit"
      ok "Removed ~/.config/systemd/user/$unit"
      removed=1
    fi
  done
  systemctl --user daemon-reload 2>/dev/null || true
  if [ "$removed" -eq 0 ]; then
    warn "Autostart was not enabled — nothing to remove."
    return 0
  fi
  printf '\n  %s\n' "Autostart disabled. (Linger left alone; you may have other --user services that need it.)"
}

_autostart_status_linux() {
  local sysd_user="$HOME/.config/systemd/user"
  if [ ! -f "$sysd_user/pager.service" ]; then
    printf '  autostart: \033[33mdisabled\033[0m (no pager.service unit installed)\n'
    return 1
  fi
  local svc_state timer_state
  svc_state="$(systemctl --user is-active pager.service 2>/dev/null || echo inactive)"
  timer_state="$(systemctl --user is-active pager-watch.timer 2>/dev/null || echo inactive)"
  if [ "$svc_state" = "active" ] && [ "$timer_state" = "active" ]; then
    printf '  autostart: \033[32menabled\033[0m (pager.service + pager-watch.timer active)\n'
    return 0
  else
    printf '  autostart: \033[33mpartial\033[0m (pager.service=%s, pager-watch.timer=%s)\n' "$svc_state" "$timer_state"
    return 1
  fi
}
