#!/usr/bin/env bash
# tests/smoke.sh — exercise every pager subcommand without touching real services.
#
# Strategy: run pager against a temporary $HOME-like sandbox so we can spin
# tmux sessions up and down without affecting the user's real sessions.
# Doesn't install systemd, doesn't touch ~/.bashrc.

set -euo pipefail

# Locate repo root regardless of where this script is invoked from.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TESTS_DIR/.." && pwd)"
PAGER="$REPO/bin/pager"

pass=0
fail=0
total=0

check() {
  local desc="$1"; shift
  total=$((total+1))
  if "$@" >/dev/null 2>&1; then
    printf '  \033[32m✓\033[0m %s\n' "$desc"
    pass=$((pass+1))
  else
    printf '  \033[31m✗\033[0m %s\n' "$desc"
    fail=$((fail+1))
  fi
}

check_output() {
  local desc="$1" expected_pattern="$2"; shift 2
  total=$((total+1))
  if "$@" 2>&1 | grep -qE "$expected_pattern"; then
    printf '  \033[32m✓\033[0m %s\n' "$desc"
    pass=$((pass+1))
  else
    printf '  \033[31m✗\033[0m %s  (expected pattern: %s)\n' "$desc" "$expected_pattern"
    fail=$((fail+1))
  fi
}

# Isolated test sandbox — its own tmux server + its own logs dir.
SANDBOX="$(mktemp -d)"

# Drop the inherited $TMUX *before* we set TMUX_TMPDIR. If we don't, every
# tmux invocation in the test reaches into the parent tmux server (the one
# this shell is attached to) instead of starting a new server under
# TMUX_TMPDIR — silently destroying test isolation and polluting the user's
# real sessions. TMUX_PANE is fine to clear for the same reason.
unset TMUX TMUX_PANE

# Use a separate tmux socket so we don't collide with the user's sessions.
export TMUX_TMPDIR="$SANDBOX/tmux"
mkdir -p "$TMUX_TMPDIR"

# Test artefacts the test will write into the real repo's logs/ dir. We
# preserve any pre-existing versions and restore them on exit, so running
# the test on a developer box with an active watchdog timer doesn't wipe
# their watch.csv history.
TEST_ARTEFACTS=("$REPO/logs/watch.csv" "$REPO/logs/smoke-test.log")
declare -a PRESERVED
mkdir -p "$REPO/logs"
for f in "${TEST_ARTEFACTS[@]}"; do
  if [ -e "$f" ]; then
    cp -p "$f" "$SANDBOX/$(basename "$f").preserved"
    PRESERVED+=("$f")
  fi
done

# shellcheck disable=SC2329  # called via trap
cleanup() {
  for f in "${TEST_ARTEFACTS[@]}"; do rm -f "$f"; done
  for f in "${PRESERVED[@]}"; do
    cp -p "$SANDBOX/$(basename "$f").preserved" "$f" 2>/dev/null || true
  done
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

export PAGER_ROOT="$REPO"

printf '\033[1m%s\033[0m\n' "pager smoke tests"
echo

# 1. binary exists and is executable
check "bin/pager is executable" test -x "$PAGER"

# 2. syntax check every shell file in repo.
# bash files first, then install.sh under POSIX sh (it's #!/bin/sh).
for f in "$REPO/bin/pager" "$REPO/lib/sudo.sh" \
         "$REPO/bootstrap.sh" \
         "$REPO/linux/bootstrap.sh" "$REPO/macos/bootstrap.sh"; do
  [ -f "$f" ] || continue
  check "syntax (bash): ${f#"$REPO/"}" bash -n "$f"
done
if [ -f "$REPO/install.sh" ]; then
  check "syntax (sh): install.sh" sh -n "$REPO/install.sh"
fi

# 3. help on bare invoke
check_output "bare invoke prints usage" 'Usage' "$PAGER"
check_output "help subcommand prints usage" 'Usage' "$PAGER" help
check_output "-h prints usage" 'Usage' "$PAGER" -h

# 4. unknown subcommand → non-zero exit + error on stderr
total=$((total+1))
if "$PAGER" bogus >/dev/null 2>&1; then
  printf '  \033[31m✗\033[0m unknown subcommand exits non-zero\n'; fail=$((fail+1))
else
  printf '  \033[32m✓\033[0m unknown subcommand exits non-zero\n'; pass=$((pass+1))
fi

# 5. status with no tmux server (yet) should not crash
check "status with no sessions" "$PAGER" status

# 6. start a sandbox session (no remote control, no actual claude — use bash as a stand-in)
# We can't actually launch claude in CI, but we CAN verify the start command builds and
# tmux session lifecycle works. Use PAGER_NO_REMOTE=1 and a fake command in PATH override.

FAKE_BIN="$SANDBOX/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/claude" <<'FAKE'
#!/usr/bin/env bash
# Stand-in for `claude` during smoke tests. Sleeps so the tmux session stays alive.
sleep 60
FAKE
chmod +x "$FAKE_BIN/claude"
export PATH="$FAKE_BIN:$PATH"

check "start: launches sandbox session" env PAGER_NO_REMOTE=1 "$PAGER" start smoke-test
sleep 1
check_output "status: lists smoke-test session" 'smoke-test' "$PAGER" status

# 7. start again — must be idempotent (already-running guard)
check_output "start (re-run) detects existing session" 'already running' "$PAGER" start smoke-test

# 8. url on a session that has no Remote Control URL must not crash
check_output "url on local session reports no URL" '(no Remote Control URL|smoke-test)' "$PAGER" url smoke-test

# 9. watchdog on a live, healthy session — should be a noop and append one CSV row.
total=$((total+1))
rm -f "$REPO/logs/watch.csv"
if env PAGER_NO_REMOTE=1 "$PAGER" watchdog smoke-test >/dev/null 2>&1 \
   && [ -f "$REPO/logs/watch.csv" ] \
   && [ "$(wc -l < "$REPO/logs/watch.csv")" -eq 2 ] \
   && awk -F, 'NR==2 { if ($3=="true" && $4!="" && $7=="noop") exit 0; exit 1 }' "$REPO/logs/watch.csv"; then
  printf '  \033[32m✓\033[0m watchdog on live session writes noop row\n'; pass=$((pass+1))
else
  printf '  \033[31m✗\033[0m watchdog on live session writes noop row\n'; fail=$((fail+1))
fi

# 10. kill named session (use `kill`, not `stop` — stop now sets the
#     .stopped semaphore which makes the next watchdog tick noop, the
#     v0.2.1 persistent-stop behavior. `kill` is the right verb when we
#     want the watchdog to respawn at the next tick.)
check "kill: drops named session" "$PAGER" kill smoke-test
total=$((total+1))
if ! "$PAGER" status 2>&1 | grep -q '^smoke-test\b'; then
  printf '  \033[32m✓\033[0m status: smoke-test gone\n'; pass=$((pass+1))
else
  printf '  \033[31m✗\033[0m status: smoke-test gone\n'; fail=$((fail+1))
fi

# 11. watchdog on a dead session — should restart and write a 'restart' row.
# Both pager and the watchdog use the default tmux socket (controlled here via
# TMUX_TMPDIR), so verify with plain `tmux has-session`, no `-L`.
total=$((total+1))
rm -f "$REPO/logs/watch.csv"
# Belt and suspenders: ensure no leftover stop semaphore from prior runs.
rm -f "$REPO/logs/.stopped"
if env PAGER_NO_REMOTE=1 "$PAGER" watchdog smoke-test >/dev/null 2>&1 \
   && tmux has-session -t smoke-test 2>/dev/null \
   && awk -F, 'NR==2 { if ($7=="restart") exit 0; exit 1 }' "$REPO/logs/watch.csv"; then
  printf '  \033[32m✓\033[0m watchdog restarts a dead session\n'; pass=$((pass+1))
else
  printf '  \033[31m✗\033[0m watchdog restarts a dead session\n'; fail=$((fail+1))
fi
"$PAGER" stop smoke-test >/dev/null 2>&1 || true

# 9b. watchdog with no claude on PATH should log action=claude-missing,
#     NOT try to restart in a loop. Verifies the v0.6.2 guard.
total=$((total+1))
rm -f "$REPO/logs/watch.csv" "$REPO/logs/.stopped"
# Override PATH to strip the FAKE_BIN that contains our stub claude.
# /usr/bin:/bin doesn't have claude either, so command -v will fail.
if env -i HOME="$HOME" PATH="/usr/bin:/bin" TMUX_TMPDIR="$TMUX_TMPDIR" PAGER_NO_REMOTE=1 \
     "$PAGER" watchdog smoke-test >/dev/null 2>&1 \
   && awk -F, 'NR==2 { if ($7=="claude-missing") exit 0; exit 1 }' "$REPO/logs/watch.csv"; then
  printf '  \033[32m✓\033[0m watchdog logs claude-missing (no restart loop)\n'; pass=$((pass+1))
else
  printf '  \033[31m✗\033[0m watchdog logs claude-missing (no restart loop)\n'; fail=$((fail+1))
fi

# 9c. pager trust: round-trip set / check / reset against a sandboxed HOME so
#     we don't pollute the developer's real ~/.claude.json.
#     Note: `pager trust --check` returns rc=1 when NOT TRUSTED — that's
#     intentional design. With smoke.sh's `set -euo pipefail`, naive pipes
#     `... | grep -q ...` would fail on those checks. Capture output first.
total=$((total+1))
TRUST_HOME=$(mktemp -d)
trust_pass=1
trust_check() {
  local expected_prefix="$1"; shift
  local got
  got=$(env HOME="$TRUST_HOME" "$PAGER" trust "$@" 2>&1 || true)
  case "$got" in
    "${expected_prefix}"*) return 0 ;;
    *) echo "    (unexpected: '$got' expected prefix '$expected_prefix')" >&2; return 1 ;;
  esac
}
trust_check 'NOT TRUSTED:' --check /tmp || trust_pass=0
trust_check 'TRUSTED:'      /tmp        || trust_pass=0
trust_check 'TRUSTED:'      --check /tmp || trust_pass=0
trust_check 'RESET:'        --reset /tmp || trust_pass=0
trust_check 'NOT TRUSTED:'  --check /tmp || trust_pass=0
# Multi-path: trust /tmp /var, then reset both, then confirm neither is trusted.
trust_multi_check() {
  local expected_count="$1" expected_prefix="$2"; shift 2
  local got
  got=$(env HOME="$TRUST_HOME" "$PAGER" trust "$@" 2>&1 || true)
  local actual_count
  actual_count=$(printf '%s\n' "$got" | grep -c "^${expected_prefix}" || true)
  [ "$actual_count" -eq "$expected_count" ] && return 0
  echo "    (got $actual_count lines starting '$expected_prefix', expected $expected_count)" >&2
  echo "    (full output: $got)" >&2
  return 1
}
trust_multi_check 2 'TRUSTED:'      /tmp /var           || trust_pass=0
trust_multi_check 2 'RESET:'        --reset /tmp /var   || trust_pass=0
trust_multi_check 2 'NOT TRUSTED:'  --check /tmp /var   || trust_pass=0
rm -rf "$TRUST_HOME"
if [ "$trust_pass" -eq 1 ]; then
  printf '  \033[32m✓\033[0m trust round-trip (check, set, check, reset, check)\n'; pass=$((pass+1))
else
  printf '  \033[31m✗\033[0m trust round-trip (check, set, check, reset, check)\n'; fail=$((fail+1))
fi

# 10. ssh subcommand without an inventory entry → clear error, non-zero
total=$((total+1))
if "$PAGER" ssh nonexistent-host >/dev/null 2>&1; then
  printf '  \033[31m✗\033[0m ssh nonexistent host exits non-zero\n'; fail=$((fail+1))
else
  printf '  \033[32m✓\033[0m ssh nonexistent host exits non-zero\n'; pass=$((pass+1))
fi

# 11. run subcommand with unknown action → clear error, non-zero
total=$((total+1))
if "$PAGER" run any not-a-real-action >/dev/null 2>&1; then
  printf '  \033[31m✗\033[0m run unknown-action exits non-zero\n'; fail=$((fail+1))
else
  printf '  \033[32m✓\033[0m run unknown-action exits non-zero\n'; pass=$((pass+1))
fi

# 12. .env.example doesn't contain any non-empty secret-looking value
total=$((total+1))
# shellcheck disable=SC2016  # intentional literal $ in regex
if grep -E '=["'\''][^"'\'']{8,}["'\'']' "$REPO/.env.example" \
   | grep -vE 'GITHUB_TOKEN="\$GH_TOKEN"|OPS_|PAGER_' >/dev/null 2>&1; then
  printf '  \033[31m✗\033[0m .env.example has suspicious literal values\n'; fail=$((fail+1))
else
  printf '  \033[32m✓\033[0m .env.example is template-only (no real secrets)\n'; pass=$((pass+1))
fi

echo
printf '\033[1mResult:\033[0m %d/%d passed' "$pass" "$total"
if [ "$fail" -gt 0 ]; then
  printf ', \033[31m%d failed\033[0m\n' "$fail"
  exit 1
fi
echo
exit 0
