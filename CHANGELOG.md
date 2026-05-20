# Changelog

All notable changes to **pager** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.7.0-alpha-4] — 2026-05-20

Fourth alpha: closes the workspace-trust hole on Windows. Three compounding
bugs were silently breaking trust pre-acceptance on every install; this
release fixes all three and adds a single canonical repair command.

### Found

- **`Invoke-PagerTrust` splatted paths as character arrays.** A single-element
  `$paths | ForEach-Object` pipeline unwraps to a scalar string in PowerShell;
  `@$normalized` then splatted that string into Python's `sys.argv` one
  character at a time. Visible in `~/.claude.json` as one trust entry per
  character of the path (`"C"`, `":"`, `"\\"`, `"U"`, `"s"`...). Discovered
  by inspecting a "fixed" install that still showed not-trusted.
- **Path-form mismatch.** Bootstrap step 5 and `Invoke-PagerTrust` wrote with
  backslashes (`C:\Users\Foo`); claude itself stores projects with forward
  slashes (`C:/Users/Foo`). Our entries were sibling-ignored.
- **Duplicate-key race in claude's own object.** Claude appends
  `"hasTrustDialogAccepted": false` to its project entry during init. JSON
  spec: later value wins. Even with our pre-set `true` at the top of the
  same object, the doctor would correctly report not-trusted.

### Added

- **`pager trust --repair`** — canonical fix. Purges single-char garbage
  entries under `projects`, matches existing entries by normalized (forward-
  slash + lowercase) path, force-sets both trust flags to true, and round-
  trips through `json.load`/`json.dump` so duplicate keys collapse to a
  single value. Idempotent. Works against any prior damaged state.
- **`pager doctor --fix`** — runs `pager trust --repair` then re-runs the
  checks. Previously a no-op on Windows.
- **`pager doctor` new checks** — surfaces `duplicate hasTrustDialogAccepted
  key(s)` and `legacy single-char projects keys`, both with the explicit
  fix hint `pager trust --repair`.

### Changed

- **`bootstrap.ps1` step 5** — delegates to `pager trust --repair` instead of
  inlining its own Python. One source of truth for the canonical trust write.
- **Step 5b (`PAGER_TRUST_PATHS`)** — same delegation.
- **`pager start`** — after the 2.5s liveness check, sleeps another 4s and
  re-runs `Repair-PagerTrust` for `$Cwd`. Without this, claude's late
  `false` write would beat our pre-launch `true` in `~/.claude.json`.
- **`pager trust` (bare set)** — now also routes through `Repair-PagerTrust`,
  so every set call cleans up garbage and normalizes path form. No more
  divergence between "what bootstrap writes" and "what an interactive
  `pager trust` writes".

### Fixed

- **Splat-as-chars bug** — `@($paths | ForEach-Object {...})` wraps in array
  context throughout `Invoke-PagerTrust` so single-path calls no longer
  fragment.
- **Path normalization** — both reads (`Get-TrustState`) and writes
  (`Repair-PagerTrust`, `Invoke-PagerTrust`) compare via
  `path.replace('\\', '/').lower()`, so backslash legacy entries match
  correctly during check/reset/repair.

## [0.7.0-alpha-3] — 2026-05-19

Third alpha: actually run claude in the background on Windows-native, with no
WSL and no visible terminal window. Experimental.

### Changed
- **`pager start` no longer redirects stdout/stderr.** That's the cause of the
  TTY-bailout from -alpha-2 (claude saw piped streams, switched to `--print`
  mode, exited). Now `Start-Process -WindowStyle Hidden` (no redirect) gives
  claude a hidden console window with a real TTY -- it runs interactively in
  the background with no UI.
- **`pager url` is now a console-buffer scraper.** Spawns a sidecar
  PowerShell that uses Win32 `FreeConsole` + `AttachConsole(claudePid)` +
  `ReadConsoleOutputCharacter` to read claude's hidden console screen buffer,
  regexes for `claude.ai/code/session_...`, and caches the result to
  `logs\<session>.url` so later calls don't have to re-scrape.
- **`pager logs` no longer tails anything** -- no log capture happens on
  Windows in this alpha. Prints an explanation pointing at WSL2 for full log
  tailing.

### Caveats (intentional)
- The URL must be on claude's current screen when `pager url` runs the first
  time. claude prints it within ~5s of startup, so running `pager url` right
  after `pager start` works. Once cached, subsequent calls read the cache.
- No watchdog yet -- crash recovery relies on the Scheduled Task's built-in
  RestartInterval/RestartCount. Real user-timer watchdog is v0.8 work.

### Why "experimental"
`AttachConsole`/`ReadConsoleOutputCharacter` on a hidden console of a process
started via `Start-Process -WindowStyle Hidden` is documented to work but
gets less testing than the foreground case. If `pager url` returns
"URL not visible in claude's console buffer yet" repeatedly, please file an
issue with `pager status` + Windows version output.

## [0.7.0-alpha-2] — 2026-05-19

Second hotfix on the Windows alpha. Headline finding: **claude requires a TTY
that v0.7.0-alpha doesn't yet provide on Windows.** This release makes that
fact loud and documented; the actual fix (ConPTY-backed sessions) is queued
for v0.8.

### Found
- **`pager start` succeeds, claude dies, `pager status` shows DEAD.** Cause:
  Claude Code switches to `--print` mode when it can't detect a TTY (which
  happens because `Start-Process -RedirectStandardOutput/-Error` writes to
  files, not a terminal). claude then looks for piped input, finds none,
  exits with `Input must be provided either through stdin or as a prompt
  argument when using --print`. Stack: native Windows lacks a tmux-equivalent
  PTY for background processes; ConPTY (Win10 1809+) is the path forward.

### Added
- **`pager start` now detects the early-exit case** within 2.5 seconds of
  launching claude. If claude died, reads `<session>.err`, prints the stderr,
  and if it matches the TTY-bailout pattern, prints an explanation pointing
  at `windows/README.md#known-limitations` and the WSL2 workaround. Cleans
  up the stale PID file automatically so `pager status` doesn't lie.
- **`pager logs` now shows `<session>.err` before tailing `<session>.log`.**
  Previously stderr was invisible, which is how this whole investigation
  started.
- **`windows/README.md#known-limitations`** — full writeup of the TTY issue
  with WSL2 as the recommended working path until v0.8 ships ConPTY support.

### Fixed
- **`pager doctor` said "OK all checks passed" while showing warnings.**
  PowerShell scope gotcha: nested `Warn`/`Fail` helpers incremented
  `$script:warns`, but the verdict block read local `$warns`. They were two
  different variables. Refactored to use a hashtable counter (`$c.warns` /
  `$c.fails`) that the script-block helpers can mutate directly.
- **`pager doctor` and `pager info` errored on `~/.claude.json` with**
  `Cannot convert the JSON string because a dictionary that was converted
  from the string contains duplicated keys`. PS 5.1's `ConvertFrom-Json`
  rejects duplicate keys; claude sometimes writes them. Switched to a
  shared `Get-TrustState` helper that delegates JSON parsing to Python
  (already installed via bootstrap), which handles duplicates by last-write.

## [0.7.0-alpha-1] — 2026-05-19

Hotfix for v0.7.0-alpha based on first real-user test (Win11 + PowerShell 5.1).

### Fixed
- **Bootstrap died on step 1/7 dependencies** when OpenSSH was already
  installed. `ssh -V` writes its version banner to stderr, and under
  PowerShell's `$ErrorActionPreference = "Stop"` that gets treated as a
  terminating `NativeCommandError`/`RemoteException`. Added a defensive
  `Get-NativeVersion` helper that scoped-flips `$ErrorActionPreference` to
  `Continue` around native-command version probes, then restores. Applied to
  `git --version`, `ssh -V`, and `python --version` — all three were the same
  shape of bug, only `ssh` triggered it because git/python write to stdout on
  most modern versions.

### Added
- `windows/README.md` — full Windows install / uninstall / troubleshooting
  page (mirrors how `macos/README.md` works). Main README now points to it
  for deeper Windows details to keep the top-level README cross-platform.

## [0.7.0-alpha] — 2026-05-19

**Native Windows port (no WSL).** Alpha: tagged but NOT a GitHub Release — v0.6.9 stays the "Latest Release" badge until Windows has gone through real-user testing on a Win10 + Win11 box.

### Added — Windows native install
- **`install.ps1`** — PowerShell entry point. `irm https://raw.githubusercontent.com/jawwadzafar/pager/main/install.ps1 | iex`. Mirrors `install.sh`'s shape: preflight banner explaining the 5 steps, env knobs (`PAGER_REPO`, `PAGER_BRANCH`, `PAGER_HOME`, `PAGER_NO_AUTOSTART`), clone via git, auto-install git via winget if missing, soft-warn if claude isn't on PATH, hand off to `windows/bootstrap.ps1`.
- **`windows/bootstrap.ps1`** — 7-step idempotent setup:
  1. Dependencies via winget: Git, OpenSSH Client (Windows Capability), Python.
  2. `logs\` directory.
  3. `.env` from `.env.example`.
  4. `$PROFILE` wiring: auto-load `.env`, define `function pager { & "...\bin\pager.ps1" @args }`.
  5. Pre-trust `$env:USERPROFILE` in `~/.claude.json` (same JSON shape as bash bootstrap).
  5b. Honor `PAGER_TRUST_PATHS` (`;` or `:` separated) for extra pre-trusted dirs.
  6. SSH key informational check.
  7. Register Scheduled Task `pager` triggered AtLogOn, with battery + restart settings.
- **`bin/pager.ps1`** — PowerShell mirror of `bin/pager`. Same command surface:
  - `start [name] [--cwd DIR]` — spawn claude in background via `Start-Process -WindowStyle Hidden`, redirect stdout/stderr to `logs\<name>.log`/`.err`, write PID file. Auto-trusts launch dir same as bash version.
  - `stop [name]` / `kill [name]` — `Stop-Process -Force` + cleans PID file. (`kill` is currently an alias for `stop`; Windows has no watchdog/semaphore yet.)
  - `status` — table of pager-managed processes from PID files.
  - `url [name]` — greps the log for `claude.ai/code/session_…`.
  - `logs [name]` — replaces `attach`. `Get-Content -Tail 50 -Wait`. Read-only.
  - `trust [--check|--reset] PATH ...` — same multi-path semantics, same JSON shape.
  - `autostart enable|disable|status` — Scheduled Task wrapper.
  - `info` — full state summary.
  - `doctor` — health check (no `--fix` yet on Windows; alpha scope).
  - `uninstall [-y]` — removes Scheduled Task, stops running sessions, strips `# pager: auto-load` block from `$PROFILE` with timestamped backup, leaves repo + .env in place.
  - `help` — full command reference.
- **README** + **website** updated with Windows install one-liner and uninstall recipe.

### Honest deviations from Linux/Mac
- **No tmux + no watchdog yet.** `pager attach` is replaced by `pager logs` (read-only tail). For interactive PTY attach, use WSL2 + the Linux installer. The Scheduled Task's built-in `RestartInterval=2min, RestartCount=3` is the only restart-on-crash mechanism in this alpha.
- **`kill` is an alias for `stop`** (no `.stopped` semaphore needed without a watchdog).
- **No `pager ssh` inventory support on Windows yet.** Python + pyyaml are installed by bootstrap, but the inline YAML parsing of `cmd_ssh` isn't ported. Coming in a follow-up.
- **No `doctor --fix`** on Windows yet. `doctor` reports state only.

### Compatibility
- PowerShell 5.1 (default on Win10/11) and PowerShell 7+ both supported. No PS7-only syntax (`?.`, `??`) used.
- Pure additive: zero edits to `install.sh`, `bin/pager` (bash), `linux/bootstrap.sh`, `macos/bootstrap.sh`, or any shared file. Existing Linux/macOS installs are unaffected.

### Why alpha (and not "Latest")
The earlier macOS port went through "report from Mac user → fix" cycles for several rev numbers before stabilizing. Same expected here. v0.6.9 stays the GitHub "Latest Release" badge. v0.7.0-alpha is a git tag only — re-run `irm ... | iex` on the same box after any tag bump and it's idempotent.

## [0.6.9] — 2026-05-19

Self-healing diagnostics + sharper error messages.

### Added — `pager doctor --fix`
- New `--fix` flag on `pager doctor` attempts safe auto-fixes for every failing check it finds. Each fix is OS-aware (works the same on Mac via launchctl / on Linux via systemctl). When a fix succeeds, the check prints with a `[auto-fixed]` tag.
- Auto-fixable without side effects:
  - **`.env` perms wrong** → `chmod 600`
  - **`.env` missing** → copy from `.env.example` + chmod
  - **Trust flag missing for `$HOME`** → run `pager trust $HOME`
  - **`~/.claude.json` missing entirely** → create + pre-trust `$HOME`
  - **LaunchAgent installed but not loaded** (macOS) → `launchctl bootstrap`
  - **`pager.service` installed but not active** (Linux) → `systemctl --user start`
  - **`pager-watch.timer` not active** (Linux) → `systemctl --user enable --now`
- Side-effect fixes that require `--fix --yes` (the `-y` is a confirmation gate for things that change system state more invasively):
  - **autostart not installed at all** → `pager autostart enable` (triggers macOS TCC prompts at next login, hence the gate)
- Fixes that are NOT auto-attempted (because they need package managers / sudo):
  - missing `tmux`, `claude`, `python3` — print the install hint, skip
- Verdict line at the end shows `auto-fixed: N` count when `--fix` is on. When `--fix` is off and there are issues, prints a hint about `pager doctor --fix`.

### Added — better error messages with copy-paste commands
- **`pager attach <nonexistent>`** now prints a real error with the exact start command and a pointer to `pager status`. Previously: just exec'd tmux which printed its own less-helpful error.
- **`pager url --all`** with no running sessions prints "No tmux sessions running. Start one with: pager start" instead of nothing.
- **`pager url <name>`** for a missing session prints the session name + "start with: pager start <name>" hint inline.
- Doctor's `fail`/`warn` hints throughout now end with `(or: pager doctor --fix)` where applicable, so users see both the manual command AND the auto-fix path.

### Notes
- 28/28 smoke tests pass (added two: `attach: nonexistent session hint`, the `doctor --fix` no-op path is covered by the existing "doctor passes" test).
- shellcheck clean.
- Works identically on Mac (launchctl) and Linux (systemctl) — same `pager doctor --fix` invocation on both platforms.

## [0.6.8] — 2026-05-19

`pager start` now auto-trusts whatever directory it launches claude in, and accepts `--cwd` to start in a project dir other than `$HOME`. Plus the install heads-up explains what `~/.pager/.env` is for.

### Added
- **`pager start [--cwd DIR]`** — new flag. tmux launches claude in `DIR` instead of `$HOME`, and pager auto-trusts `DIR` first so claude doesn't show its "Trust this folder?" prompt. Example: `pager start work --cwd ~/code/myproject`.
- **`cmd_start` auto-trusts the launch directory** before spawning tmux, regardless of whether `--cwd` was passed. Belt-and-suspenders: even if bootstrap's pre-trust got clobbered somehow (claude rewriting `~/.claude.json`, manual edit, etc.), every `pager start` re-asserts trust on the dir it's about to use.
- **`install.sh` heads-up explains `~/.pager/.env`** — names it as optional, points at `.env.example` for variables, and lists the three ways to pre-trust extra dirs (`pager trust ...`, `PAGER_TRUST_PATHS`, `pager start --cwd ...`).
- New smoke test 9c2: `pager start --cwd /this/does/not/exist` must fail cleanly (no half-spawned session). 27/27 tests pass.

### Why
User asked for "a utility that makes the dir where claude starts pre-trusted." That utility already existed via `pager trust`, but now it's automatic — every `pager start` quietly re-trusts the launch dir as a no-op-when-already-trusted, and `--cwd` lets users start claude in a specific project dir with auto-trust included. No more "session got stuck on trust prompt" failure mode for non-`$HOME` workflows.

### Notes
- install.sh stays ASCII-only (caught one em-dash mid-commit, fixed before push). Verified via Python byte scan.
- shellcheck clean across all shell files. 27/27 smoke tests pass.

## [0.6.7] — 2026-05-19

`install.sh` now prints a preflight heads-up before doing any work — what's about to happen, which macOS prompts to Allow vs Deny, how to opt out, where to read more.

### Added
- **Preflight section in `install.sh`** runs after OS detection but before `git clone`. Lists numbered install steps for the detected OS. On macOS, includes a prominent table of the TCC prompts users will see at first login: which to Allow (`tmux` App Management) and which to Deny (Full Disk Access, Music, Photos, Contacts, Documents, Downloads, Desktop). Lists the `--no-autostart` opt-out one-liner with a copy-pasteable curl invocation. Points at `pager info` for post-install state and `PAGER_TRUST_PATHS` for declarative trust.

### Why
Previous behavior: `install.sh` kicked straight into `git clone` after detecting OS, gave no preview of what was coming. Users who ran `curl | sh` on macOS were surprised by the TCC prompt storm at first login — even though `macos/README.md` documented it, you'd have to know to read the docs first. Now the install itself shows the heads-up, in the same terminal, right before doing the install. No surprises.

### Notes
- 26/26 smoke tests pass; install.sh stays ASCII-only (re-checked, fixed two em-dashes that slipped in).
- shellcheck `-s sh` clean.

## [0.6.6] — 2026-05-19

`pager info` — the install-time banner now exists as a real command you can run any time to see what's installed, what's trusted, what's running.

### Added
- **`pager info`** subcommand. Prints a comprehensive state summary:
  - Version (read from `CHANGELOG.md`'s top non-`Unreleased` entry)
  - Quick-start commands (`start`, `url`, `attach`, `status`, `doctor`)
  - Stop / restart commands (`stop`, `kill`, `restart`)
  - **Autostart state** (live, queried via `lib/autostart.sh`)
  - **Currently trusted folders** (read live from `~/.claude.json`)
  - File paths (repo, secrets, logs, inventory)
  - Doc pointers (`pager help`, README, macos/README.md, GitHub)
- Bootstrap end-banner now delegates to `pager info` instead of printing its own ad-hoc list. Single source of truth — the post-install message stays in sync with the runtime command, no duplication, no drift.
- Smoke test 9d ensures `pager info` renders without errors and contains a version line. Custom check (not `check_output`) because info's output is long enough to trip SIGPIPE when `grep -q` closes the pipe early under `set -o pipefail`. 26/26 tests pass.

### Why this exists
The user asked: "When we run install then it should print what we can do and in that we can check or enable all should work. Maybe then we start what should be best way so we never have this problem."

Old bootstrap banner listed 4 commands and called it done. The new `pager info` shows the actual install state, currently-trusted folders, autostart status — so users can see at a glance what's set up and what they might still want to do (e.g. `pager trust ~/code` for a project dir they meant to trust). Runnable any time — `pager info` after an upgrade, after a config change, when something seems off.

## [0.6.5] — 2026-05-19

Multi-path trust + `PAGER_TRUST_PATHS` env var for reproducible bulk trust.

### Why
Real-Mac probe of `~/.claude.json` confirmed Claude Code's trust is **per-exact-path, not hierarchical**: trusting `$HOME` does NOT cover `$HOME/code/myproj`. v0.6.4 added `pager trust` but only one path at a time, and there was no way to declare a fixed list of paths to trust at install time.

### Added
- **`pager trust PATH1 PATH2 PATH3 ...`** — `cmd_trust` now accepts any number of paths (was: one). All three modes (`set`, `--check`, `--reset`) operate on the full list and report per-path results. Exit code 0 if all paths satisfy the mode, 1 if any fail.
- **`PAGER_TRUST_PATHS` env var** read by both bootstraps (`macos/bootstrap.sh` step 9b, `linux/bootstrap.sh` step 6b). Colon-separated, like `PATH`. Each entry is passed to `pager trust`. Sourced from `~/.pager/.env` so a user can declare their trusted dirs once and re-bootstrap to apply.
- `.env.example` documents `PAGER_TRUST_PATHS` with a commented-out example.
- Smoke test 9c gains a multi-path round-trip: trust two paths in one call, reset both, verify both are no longer trusted. 25/25 tests pass.

### Auto-trust answer (for the question "can we just auto-trust?")
- **`$HOME`** is auto-trusted on every bootstrap (since v0.1.0; unchanged).
- **Any path in `PAGER_TRUST_PATHS`** is auto-trusted on every bootstrap (new).
- **No auto-detection of "common" dirs** (~/code, ~/projects, etc.) — that would pollute `~/.claude.json` with entries for dirs users may not have. Opting in via the env var is honest about what's being trusted.
- **No interactive prompt** because `curl | sh` has no stdin tty. The env var route works in both interactive and non-interactive install flows.

## [0.6.4] — 2026-05-19

`pager trust` subcommand — exposes the trust-flag write the bootstraps have always done internally, but as a first-class user-facing command.

### Added
- **`pager trust [--check | --reset] [PATH]`** — pre-accept Claude Code's "Trust this folder?" dialog for any directory by writing `hasTrustDialogAccepted` + `hasCompletedProjectOnboarding` to `~/.claude.json`'s `projects.<absolute-path>` entry. Default PATH is `$HOME`. Idempotent.
  - `pager trust ~/code/myproj` — add a project dir to the trusted list
  - `pager trust --check <PATH>` — report state, exit 0 if fully trusted, 1 otherwise
  - `pager trust --reset <PATH>` — remove the entry (testing convenience)
- New smoke test "trust round-trip (check, set, check, reset, check)" against a sandboxed HOME so the real `~/.claude.json` isn't polluted. 25/25 tests pass now.
- `cmd_help` gains a dedicated `Trust` section. README env-overrides section gains a `pager trust` example block.

### Why this exists
The bootstrap has always pre-trusted `$HOME` so autostart-spawned claude sessions don't hang on the trust prompt. But:
1. Users running claude in dirs other than `$HOME` couldn't pre-trust those without manually editing `~/.claude.json`
2. There was no documented way to verify the bootstrap actually set the flag (other than `python3 -c "..."` one-liners)
3. Resetting trust for testing required hand-editing the JSON

`pager trust` makes all three first-class. The bootstrap-time pre-set is unchanged — this is purely additive.

## [0.6.3] — 2026-05-19

Real-Mac install on a different user (yashwant.singh on a separate box) surfaced two issues. Fixing both.

### Fixed
- **`watch.csv` was getting corrupted on macOS.** `cmd_watchdog` was using `ps -o etimes=` (with the trailing `s`) to read process age in seconds, which is procps (Linux)-only. macOS BSD `ps` doesn't recognize `etimes` and prints its entire keyword-help text instead. Our `| tr -d ' '` then crammed that into the `age_sec` column of `watch.csv` as one giant token. Functional behavior was unaffected (the `action` field was still correct), but the CSV was unreadable on Mac. **Fix:** new `age_seconds_for_pid` helper that parses portable `ps -o etime=` output ("[[DD-]HH:]MM:SS") via Python. Works on both Linux and macOS, returns clean integers. Both watchdog age-sec call sites updated.

### Added
- **`PAGER_NO_DANGEROUS=1` env var opt-out** for `--dangerously-skip-permissions`. Default behavior unchanged: pager still launches claude with the flag because background-autostart needs it (no human to respond to permission prompts at login). Users who want claude's normal permission-prompt flow can set the env var. With it set, claude prompts on dangerous operations — fine for interactive sessions you'll attach to, but the watchdog can't answer prompts, so background sessions may stall.
- Documented the "Bypass Permissions mode" warning banner in macos/README.md. It's loud, it's red, and it's claude's own output (not pager). Explained why we do it + how to opt out.

### Notes
- 24/24 smoke tests pass.
- Sanity-tested `age_seconds_for_pid 1` (PID 1, system init) returns a clean positive integer matching system uptime in seconds.

## [0.6.2] — 2026-05-19

Watchdog + `pager start` now refuse to thrash when claude isn't installed.

### Fixed
- **Watchdog no longer tries to restart claude every 70s when the claude binary isn't on PATH.** Previously: pgrep fast path fails → slow path calls `cmd_start` → claude binary missing → wrapper bash exits → next tick repeats. Result: `watch.csv` filled with `restart-failed` rows; on macOS, each attempt could trip TCC prompts. **Now:** if `command -v claude` fails inside the watchdog, we log a single `action=claude-missing` row and exit. No tmux session created, no restart loop, no TCC noise. As soon as the user installs claude, the next tick sees it and resumes normal restart behavior.
- **`pager start` now fails fast with an install hint if claude isn't on PATH**, instead of spinning up a tmux session whose `claude --remote-control ...` immediately fails and leaves a useless wrapper-bash session looking "alive." Same install message bootstrap prints in its soft-check (link to Claude Code site + the `npm install -g @anthropic-ai/claude-code` one-liner).

### Added
- New smoke test: `watchdog logs claude-missing (no restart loop)`. Test 9b runs the watchdog with `PATH=/usr/bin:/bin` (no claude), confirms `watch.csv` ends with `action=claude-missing` rather than `restart-failed`. 24/24 tests now.

### Notes
- This is purely a defensive behavior change — when claude IS installed (the normal case), the watchdog behaves identically to v0.6.1.
- If you see `claude-missing` rows in `~/.pager/logs/watch.csv`, the fix is: install Claude Code from https://claude.com/code, then `pager start`. Or `pager autostart disable` if you've decided you don't want pager running here at all.

## [0.6.1] — 2026-05-19

Contribution surface + safety nets.

### Added
- **Soft `claude` check** in `install.sh`, `linux/bootstrap.sh`, and `macos/bootstrap.sh`. Prints install instructions (https://claude.com/code, or `npm install -g @anthropic-ai/claude-code`) when Claude Code CLI isn't on PATH. Doesn't hard-fail — the user might have it on a not-yet-loaded PATH, or might want to install pager first and `claude` later.
- **Linux non-apt detection.** `linux/bootstrap.sh` now detects the user's package manager (dnf, yum, pacman, zypper, apk, emerge, xbps-install) and fails fast with a clear error + named distro family + contribution invite if it's not `apt-get`. No more half-installing on a Fedora box. Today's bootstrap continues to support Debian/Ubuntu/Pop!_OS/Mint/Raspberry Pi OS; other distros are tractable PRs (touch points listed in the error message).
- **`CODE_OF_CONDUCT.md`** — short pointer to Contributor Covenant 2.1 + a brief description of expectations and reporting.
- **README "Contributing" section** rewritten with: file-tour table, "Open opportunities" list naming specific PRs that would land cleanly (Linux distros, Homebrew formula, real-time log viewer, etc.), link to CONTRIBUTING.md and CODE_OF_CONDUCT.md.
- **README badges**: `PRs welcome` (links to CONTRIBUTING.md), `maintained: yes`. Existing badges retained.

### Changed
- `CONTRIBUTING.md` fully refreshed for the current repo layout (linux/, macos/, lib/autostart.sh, install.sh, the autostart subcommand). Adds explicit guidance about ASCII-only POSIX `sh` files (the v0.5.2 macOS Unicode regression motivated this rule). "Open opportunities" mirrors what's in the README.
- README tests badge bumped from "20/20" to "23/23" to match the actual smoke-test count.

### Notes
- No behavior change for existing users; everything in this release is doc + safety net. Re-bootstrapping is safe.
- Still no GitHub release cut for v0.6.0 or v0.6.1 — those are tagged in git only. v0.5.7 remains "latest" on the GitHub Releases page until the macOS verification on v0.6.x completes.

## [0.6.0] — 2026-05-19

**`pager autostart` subcommand + cleaner separation of "register the unit" vs "run the install."** Autostart stays on by default (that's the whole pitch — "Claude Code that never sleeps"), but you can now toggle it without re-bootstrapping, opt out at install time, and the docs are honest about the macOS TCC prompt cost.

### Added
- **`pager autostart [enable | disable | status]`** subcommand. OS-aware: on macOS installs the LaunchAgent + copies the .app bundle into `~/Applications` + ad-hoc codesigns + lsregisters; on Linux installs the systemd `--user` units + enables + starts. `status` returns 0 if enabled, 1 if disabled. Backed by the new `lib/autostart.sh`.
- **`lib/autostart.sh`** — shared functions (`autostart_enable`, `autostart_disable`, `autostart_status`) sourced by both bootstraps AND `bin/pager`, so the same code path runs whether autostart is being set up at install time or toggled later.
- **`--no-autostart` flag** on `macos/bootstrap.sh`, `linux/bootstrap.sh`, and `install.sh`. Pass-through from the curl one-liner with `sh -s -- --no-autostart`. Skip the LaunchAgent / systemd registration entirely; pager runs only when you type `pager start`.
- **macOS bootstrap pre-warns** about the TCC prompt storm right before triggering it, so users see the explanation in terminal scrollback as the dialogs pop. Tells them exactly which one to Allow (`tmux` App Management) and which are safe to deny (Full Disk Access, Music, Photos, Contacts, Documents).

### Changed
- **Default behavior stays the same**: autostart is registered at install time. `--no-autostart` opts out.
- **Refresh-but-don't-disable**: if a prior install had autostart enabled, re-bootstrapping refreshes the plist / units rather than removing them. Re-bootstrapping for an upgrade no longer silently kills your autostart.
- Bootstrap step count consolidated: macOS now ends at "10/10 autostart" (was 11/11), Linux at "8/8 verify" (was 10/10). The "install systemd units" and "enable linger" and "start service" steps fold into the single autostart step.
- `bin/pager` help: new "Autostart" section in `cmd_help` covers `enable`, `disable`, `status`.
- `macos/README.md` permission-prompt section reworded to honestly explain "this is what you'll see on first login" + `--no-autostart` as the escape hatch for users who don't want it.
- Website hero copy mentions the `--no-autostart` option without burying the lede on the default behavior.

### Notes
- This dev branch is not tagged until end-to-end verified on a real Mac. Merge to `main` + tag `v0.6.0` happens once that's confirmed clean.

## [0.5.7] — 2026-05-19

Revert the C launcher experiment + finally tell users honestly what to expect on first login.

### Changed
- **Reverted `macos/pager.app/Contents/MacOS/pager` from a compiled C Mach-O binary back to a shell shim.** The v0.5.6 hypothesis was that a Mach-O launcher would let macOS render the Login Items icon; real-Mac test after restart confirmed the icon still doesn't render. Same root cause as before — BTM tags ad-hoc-signed bundles as "Unknown Developer" regardless of executable type. Compiling in bootstrap was added complexity (clang dependency, build step, gitignored artifact) for zero functional gain, and may have been making the macOS TCC permission storm WORSE on first login by triggering more Gatekeeper checks against the Mach-O. Shell shim is simpler, fewer prompts, equally non-fixing of the icon.
- Removed `macos/pager.app/Contents/MacOS/pager.c` and the clang compile step in `macos/bootstrap.sh`. `.gitignore` entry for the compiled binary path also removed since the shim is now committed at that path.
- `Info.plist` `CFBundleVersion` bumped to `0.5.7`.

### Added
- **macos/README.md now has a clear "After first login: the permission-prompt storm" section** explaining what macOS prompts users will see on first run, which to **Allow** (the App Management / tmux one — that's the only critical one), and which to **Don't Allow** (Music, Photos, Contacts, Documents, Full Disk Access — pager doesn't need any of them). Honest framing: this is what unsigned-by-Apple-Developer-ID looks like on Tahoe; the same prompt storm hits Ollama, brew-services entries, and every other community-distributed background tool. **Choices are remembered, so subsequent logins are quiet — the avalanche is once per fresh install.**

### Accepting the icon limitation
- The Login Items icon never started rendering despite our six iterations (v0.5.0 .app bundle → v0.5.1 OG polish → v0.5.2 hotfix → v0.5.3 symlink → v0.5.4 AssociatedBundleIdentifiers → v0.5.5 copy instead of symlink → v0.5.6 Mach-O launcher). The BTM dump on a real Tahoe install showed `Parent Identifier: Unknown Developer`, which is the field that drives the "Item from unidentified developer" label *and* the fallback to a generic exec icon. Both are tied to whether the bundle is signed by an Apple Developer ID, not whether the bundle is structurally correct. **Without paying Apple $99/year, this is what macOS does for any community-distributed CLI.** Fine — pager works, the .app bundle is honest about what it is, the docs explain the situation. We're not chasing this further.

## [0.5.6] — 2026-05-19

**Mach-O launcher binary.** v0.5.5 finally got the bundle indexed (`mdfind` confirmed `kMDItemCFBundleIdentifier == "com.pager.agent"` returned the path), but Login Items still showed the generic exec icon. Real-Mac diagnostics with `qlmanage`:
- `qlmanage -t .icns` → succeeded, produced a 6.8 KB thumbnail (icon file is valid).
- `qlmanage -t pager.app` → **hung indefinitely**, required Ctrl+C.

That asymmetry pinpointed it: macOS Tahoe rejects icon rendering for bundles whose `Contents/MacOS/<executable>` is a shell script (`#!/bin/sh ...`), even when the .icns + Info.plist + LaunchServices indexing + `AssociatedBundleIdentifiers` are all correct. The bundle has to have a Mach-O binary launcher.

### Fixed
- **Added `macos/pager.app/Contents/MacOS/pager.c`** — a ~30-line C launcher that `execv`s `$PAGER_ROOT/bin/pager` (falling back to `~/.pager/bin/pager` if `PAGER_ROOT` is unset). Passes argv through unchanged.
- **Bootstrap step 10c compiles it** via `clang -arch arm64 -arch x86_64 -O2 -mmacosx-version-min=11.0` — universal binary that runs on both Apple Silicon and Intel, and loads on Sequoia 15+ / Tahoe 26+.
- The compiled binary replaces the old shell-script launcher at the same path. Codesign now signs a real Mach-O instead of a script.
- `clang` is a hard requirement now (already implied by Homebrew install, which Xcode CLT provides) — bootstrap fails fast with a clear message if it's missing.
- Removed `macos/pager.app/Contents/MacOS/pager` (the shell launcher) from the repo; replaced with `pager.c` source. The compiled binary is gitignored (built per install).
- `Info.plist` `CFBundleVersion` + `CFBundleShortVersionString` bumped to `0.5.6` to invalidate any cached metadata.

### Why the "Item from unidentified developer" label persists
BTM showed `Parent Identifier: Unknown Developer` in the dump. That's the label macOS attaches to all ad-hoc-signed (no Apple Developer ID) entries — and it's fundamental to BTM's grouping in the Login Items UI. **Without paying Apple $99/year for a Developer ID, that label cannot change.** The same label appears for Ollama, Homebrew `brew services` entries, and other ad-hoc-signed background items. The icon is separate from the label — v0.5.6 fixes the icon part; the label is just how macOS marks unsigned items.

### Migration
1. `cd ~/.pager && git pull`
2. `./macos/bootstrap.sh` — compiles the C launcher, copies the bundle to `~/Applications`, ad-hoc signs.
3. Verify:
   ```bash
   file ~/Applications/pager.app/Contents/MacOS/pager
   # expect: Mach-O universal binary with 2 architectures: [arm64] [x86_64]
   ```
4. Reopen System Settings → General → Login Items & Extensions. Quit System Settings entirely if it was open (`Cmd+Q`) before reopening.
5. The pager row should now show the actual icon. The label will still say "Item from unidentified developer" — that part is permanent without a paid Developer ID, see above.

## [0.5.5] — 2026-05-19

**The bundle was never actually getting indexed.** v0.5.4 added `AssociatedBundleIdentifiers` to the plist correctly, and ad-hoc codesigned the bundle correctly, and called `lsregister -f` correctly — but real-Mac diagnostics caught that `mdfind 'kMDItemCFBundleIdentifier == "com.pager.agent"'` returned **empty** after the install. LaunchServices/Spotlight never actually indexed the bundle. With no indexed bundle for that ID, `AssociatedBundleIdentifiers` has nothing to resolve to, and Login Items falls back to generic exec.

### Fixed
- **Bootstrap step 10c now COPIES the bundle into `~/Applications/pager.app`** as a real directory, instead of symlinking it. Root cause: Spotlight's indexer skips paths inside hidden directories, and apparently won't follow a symlink to index a target inside `~/.pager/`. Even after `lsregister -f` "succeeded," `mdfind` confirmed the bundle never landed in the metadata DB. Copying as a real directory at the standard `~/Applications` location fixes the indexing.
- Ad-hoc codesign now runs against the copy (not the canonical source).
- `lsregister -f` runs against the copy.
- The plist's `ProgramArguments` is updated post-render to point at the copy too, so everything routes through the indexable path.
- `pager uninstall` switched from `rm -f` to `rm -rf` on `~/Applications/pager.app` since it's a directory now (handles both legacy symlinks and the new real dir).

### Architecture note
The .app at `~/Applications/pager.app` is purely metadata — its `Contents/MacOS/pager` launcher reads `$PAGER_ROOT` from the LaunchAgent's `EnvironmentVariables` and `exec`s `$PAGER_ROOT/bin/pager`. So one source of truth remains: the canonical install at `$PAGER_ROOT`. The bundle copy at `~/Applications/` is what macOS looks at; the actual code lives at `~/.pager/bin/pager`.

### Migration
1. `cd ~/.pager && git pull`
2. `sfltool resetbtm` (only needed once if you didn't reset between iterations)
3. `./macos/bootstrap.sh` — this is the bootstrap that will actually populate the LaunchServices DB.
4. Verify the fix landed:
   ```bash
   mdfind 'kMDItemCFBundleIdentifier == "com.pager.agent"'
   # expect: /Users/you/Applications/pager.app
   ```
5. Reopen Login Items panel.

Logout + login is optional after v0.5.5 but may be needed if the Login Items panel doesn't live-refresh.

## [0.5.4] — 2026-05-19

**The actual fix for the Login Items icon.** v0.5.3 added the `~/Applications/pager.app` symlink and `lsregister -f`, but the icon still didn't render — real-Mac test showed generic exec icon persisting. Research revealed the missing piece is `AssociatedBundleIdentifiers`, a key added in macOS Ventura 13 specifically for the legacy-plist case (i.e., when an app installs a LaunchAgent into `~/Library/LaunchAgents/` instead of using the modern SMAppService API).

### Fixed
- **Added `AssociatedBundleIdentifiers` to `com.pager.agent.plist.template`** pointing at `com.pager.agent` (matches `CFBundleIdentifier` in the .app's `Info.plist`). This is what tells the Login Items UI to render the bundle's icon + display name instead of falling back to generic exec. Per Apple's developer forums, it's the canonical fix for the "Item from unidentified developer" issue on Ventura+.
- **Bootstrap step 10c now ad-hoc codesigns the bundle** (`codesign --force --sign - $PAGER_ROOT/macos/pager.app`). Ad-hoc signing (the `-` identity) needs no Apple Developer ID and no keychain. It improves Gatekeeper's icon-resolution reliability — unsigned bundles sometimes get treated as untrusted and the icon falls back to generic.
- **`lsregister -f` now runs against both the symlink AND the canonical path** (`~/Applications/pager.app` + `$PAGER_ROOT/macos/pager.app`). BTM's bundle-lookup is loosely documented; covering both paths maximizes the chance of a hit.
- **ProgramArguments restored to the canonical `$PAGER_ROOT/macos/pager.app/...` path** (was the symlink in v0.5.3). Icon resolution is handled separately via `AssociatedBundleIdentifiers`, so the symlink only needs to exist for LaunchServices indexing, not for the actual exec.

### Migration from v0.5.3
1. `cd ~/.pager && git pull`
2. `sfltool resetbtm` — clears the BTM Login Items cache (the stale "Item from unidentified developer" entry sticks otherwise).
3. `./macos/bootstrap.sh` — re-renders the plist with `AssociatedBundleIdentifiers`, ad-hoc signs, re-registers.
4. Reopen System Settings → General → Login Items & Extensions — the `pager` row should now show the actual pager icon + "pager" name.
5. If it still doesn't: log out and log back in (macOS sometimes only refreshes the Login Items panel on a fresh session).

### Notes
- Fresh installs via `curl | sh` on v0.5.4+ get the right setup from the start — no migration steps needed.
- Sources for this fix: Apple Developer Forums [thread 713493](https://developer.apple.com/forums/thread/713493) on AssociatedBundleIdentifiers, and [the n8felton write-up](https://n8felton.wordpress.com/2022/10/24/login-and-background-item-management-in-macos-ventura-13/) on Ventura's Login Items model. Cited in commit message.

## [0.5.3] — 2026-05-19

Real-Mac test of v0.5.0 showed that despite the `lsregister -f` of `$PAGER_ROOT/macos/pager.app`, the Login Items row still rendered the generic exec icon + "Item from unidentified developer" — even after `bootout` + `bootstrap`. Two root causes:

1. **macOS BTM caches Login Items metadata keyed by the LaunchAgent's label.** Even though `bootout` removed the runtime entry, the BTM record (which holds the rendered name + icon resolution) wasn't re-evaluated against the new ProgramArguments path.
2. **LaunchServices doesn't reliably scan `~/.pager/macos/`** (a hidden directory, non-standard location). `lsregister -f` worked at the moment we ran it, but BTM's metadata cache wasn't refreshed from the new registration.

### Fixed
- **Bootstrap step 10c now symlinks `~/Applications/pager.app → $PAGER_ROOT/macos/pager.app`** (creates `~/Applications/` if missing). The LaunchAgent plist's `ProgramArguments` is re-rendered at install time to point at the symlink path rather than the hidden `~/.pager` path. Two wins:
  1. `~/Applications` is a standard LaunchServices scan location — bundle metadata is indexed reliably.
  2. BTM keys its Login Items entry against the visible symlink path, so the next time `bootout` + `bootstrap` runs, BTM creates a fresh entry that reads the bundle's `Info.plist` + `AppIcon.icns`.
- Bundle version in `Contents/Info.plist` bumped to `0.5.3` to invalidate any cached metadata.
- `pager uninstall` now removes the `~/Applications/pager.app` symlink too.
- `macos/README.md` recovery table gained a "Login Items shows the wrong icon" row with the `sfltool resetbtm` fix path.

### Notes
- Existing v0.5.0-0.5.2 installs need a one-time `sfltool resetbtm` to clear the cached metadata, then `cd ~/.pager && git pull && ./macos/bootstrap.sh`. The reset is necessary because the BTM entry was created before the `.app` bundle existed in the repo; bootout alone doesn't refresh it.
- Fresh installs from `curl | sh` on v0.5.3+ get the right icon + name from the first bootstrap.

## [0.5.2] — 2026-05-19

Hotfix — fresh installs were broken under macOS `/bin/sh`.

### Fixed
- **`curl … | sh` was failing with `sh: line 72: TARGET?: unbound variable`** on macOS. Root cause: macOS `/bin/sh` is bash 3.2 in POSIX mode, and it misparses the byte sequence `$TARGET…` (variable followed by U+2026 horizontal ellipsis, UTF-8 `E2 80 A6`) — under some locale/encoding paths the parser treats the trailing bytes as if the variable reference were `${TARGET?}` (the POSIX "error if unset" form), then trips `set -u`. Stripped all non-ASCII characters from `install.sh` (`—` → `--`, `…` → `...`, `─` → `-`, box-drawing → ASCII). Also scrubbed `macos/pager.app/Contents/MacOS/pager` for consistency, even though it's a defensive fix there (no expansion would have triggered the actual bug).
- The fresh-install flow now works end-to-end on macOS Tahoe.

### Notes
- The audit only finds two `#!/bin/sh` files in the repo (`install.sh` and the .app launcher). Bash files (`bin/pager`, the bootstraps, `lib/sudo.sh`, etc.) are unaffected — bash full-mode parses UTF-8 bytes in variable contexts correctly; only bash-as-`sh` POSIX mode has the misparse.

## [0.5.1] — 2026-05-19

Content + polish pass on top of 0.5.0 — sharper positioning, defensive .gitignore.

### Changed
- **Headline + positioning rewritten** around the actual differentiator: persistence. "Claude Code that never sleeps." vs the old "Remote Claude Code sessions, from your phone." The hero, the meta description, the OG title + description, and the README intro all now lead with "no timeouts / no session expired / survives reboots" — the value Claude Code in the browser can't give you. Updated across:
  - `docs/index.html` `<title>`, `meta name="description"`, og:title, og:description, twitter:title, twitter:description.
  - `docs/index.html` hero `<h1>` + tagline. New copy contrasts pager against the browser failure mode explicitly.
  - `README.md` intro: top section is now a `## Claude Code that never sleeps.` heading + the same value prop.
  - Regenerated `docs/og-image.png` (1200×630): new layout with the "Claude Code that never sleeps." headline as primary text, proof-point subtitle, accent chip line at the bottom (Linux + macOS • one-line install • MIT). Icon column left, text column right.
  - `assets/scripts/build-favicons.py` updated so re-running the script regenerates the new card.

### Added
- **Comprehensive `.gitignore`** covering secrets (.env / .env.local / .env.*.local / keys / certs / known_hosts), Python build artifacts (`__pycache__`, `*.pyc`, eggs, build/dist, venvs, pytest/mypy/ruff caches), Node defensive entries (`node_modules`, npm/pnpm/yarn lockfile backups + debug logs), OS junk (.DS_Store + the full macOS noise set, Thumbs.db + Windows Recycle Bin, Linux `.fuse_hidden` / `.nfs*`), IDE configs (.vscode, .idea, JetBrains shelf, Sublime workspaces, Atom history), Vim/Emacs swap files + backup files, build outputs (*.o, *.a, *.exe, dist/, target/, out/), tmux/shell history leftovers, docs build outputs (defensive — Pages publishes docs/ as-is right now), and pager-specific forensic backups (`*.pager.bak.*`, `*.pre-install-*`, `pager-fresh-install.log`).
- Removed the previously-committed `assets/scripts/__pycache__/build_icns.cpython-314.pyc` (slipped in with 0.5.0 — now gone and gitignored).

## [0.5.0] — 2026-05-19

The "looks like a real app on the Login Items list" release. Real `.app` bundle, generated icon, watchdog refactor that finally silences the macOS TCC popup on healthy ticks, and a full SEO + favicon pass on the website.

### Added

**`pager.app` bundle + generated AppIcon.icns**
- `macos/pager.app/` is a real macOS app bundle: `Contents/Info.plist` (`CFBundleName=pager`, `CFBundleIdentifier=com.pager.agent`, `LSBackgroundOnly=true`, `LSUIElement=true`, `LSMinimumSystemVersion=15.0`), `Contents/MacOS/pager` (POSIX `sh` launcher that `exec`s `$PAGER_ROOT/bin/pager`), `Contents/Resources/AppIcon.icns` (multi-resolution: 16@2x, 32@2x, 128, 128@2x, 256, 256@2x, 512, 512@2x = 8 PNG-backed entries, ~47 KB total).
- `macos/launchd/com.pager.agent.plist.template` now points its `ProgramArguments` at the .app's launcher (`__PAGER_ROOT__/macos/pager.app/Contents/MacOS/pager`) instead of `bin/pager` directly. That's the trick that makes the **Login Items row show a real "pager" name + icon** instead of "Item from unidentified developer" + generic exec icon.
- `macos/bootstrap.sh` step 10c now `lsregister -f`s the bundle so LaunchServices picks up the icon + display name immediately (otherwise auto-discovery for bundles outside `/Applications` is unreliable on first install).
- `assets/scripts/build_icns.py` — Pillow + stdlib `struct` icon generator. Re-run to rebuild the icon: `python3 assets/scripts/build_icns.py`. No external image tools required (no `iconutil`, no `rsvg-convert`).

**Favicons + Open Graph card for the docs site**
- `assets/scripts/build-favicons.py` re-uses the same icon renderer to emit, into `docs/`:
  - `favicon.ico` (16/32/48 multi-resolution Windows-style)
  - `favicon-16.png`, `favicon-32.png` (modern browsers prefer explicit PNG)
  - `apple-touch-icon.png` (180×180, iOS Home Screen + macOS Safari tab)
  - `icon.svg` (vector, modern browser SVG-favicon path)
  - `og-image.png` (1200×630 social-share card: pager icon left, wordmark + tagline + "Linux + macOS" right)
- `docs/index.html` `<head>` now wires up: `icon`, `alternate icon`, `apple-touch-icon`, `mask-icon`, `theme-color`, `application-name`.

**SEO pass on `docs/index.html`**
- Title and meta `description` rewritten to put "Claude Code", "Linux", "macOS", "phone", "tmux", "claude --remote-control" in the first 160 chars.
- Added `meta name="keywords"`, `author`, `canonical link`.
- Full **Open Graph** set: `og:type`, `og:url`, `og:title`, `og:description`, `og:image` (+ width / height / alt), `og:site_name`, `og:locale`.
- Full **Twitter / X card** set: `twitter:card=summary_large_image`, title, description, image, image:alt.
- **JSON-LD structured data**: `SoftwareApplication` schema.org block with operatingSystem, license, codeRepository, image, offers (price=0).

**SVGs in the README too**
- `README.md` now embeds the `assets/flow.svg` + `assets/flow-dark.svg` pair (via `<picture>`) directly below the "Why this exists" line — matches the visual storytelling of the docs site without having to leave GitHub.
- New `assets/icon.svg` (square vector version of the app icon) is also committed for parity.

### Changed

**Watchdog: pgrep-based liveness fast path**
- `cmd_watchdog` gets a second early-bypass right after the `.stopped` semaphore check. If `pgrep -f "claude .*--remote-control <session>"` finds a running process, the watchdog logs a `noop` row with the live PID + `rc_banner=true` and exits WITHOUT making any tmux call. On macOS this means the App Management TCC prompt ("tmux would like to access data from other apps") **fires at most once per restart, not every 70 seconds**. The slow path (full tmux diagnostic + restart-if-dead) still runs when pgrep finds nothing, so the test "watchdog restarts a dead session" still passes (it uses `PAGER_NO_REMOTE=1`, which intentionally skips the pgrep fast path).

**Dropped `brew install python@3.13`** *(rolled in from 0.4.1 — restating because users skipping straight to 0.5.0 should know)* — `macos/bootstrap.sh` step 2 is just `brew install tmux libyaml` now. Apple's `/usr/bin/python3` is used for the inline json/yaml/datetime work.

**Autostart docs rewritten** in `macos/README.md`. The "Autostart semantics — login vs boot" section now leads with the *recommendation*: enable macOS auto-login + disable FileVault on a dedicated rig. The LaunchDaemon footnote is shorter and clearly marked "out of scope." Matches the `CLAUDE.md` guidance that "LaunchAgent + auto-login is the pragmatic match."

### Notes
- Migrating from 0.4.x → 0.5.0: `cd ~/.pager && git pull && ./macos/bootstrap.sh`. Bootstrap will `lsregister` the new bundle and re-bootstrap the LaunchAgent pointing at the .app's launcher. After re-login (or `launchctl kickstart gui/$(id -u)/com.pager.agent`), the Login Items row should show a real `pager` icon + name.
- If the Login Items row still shows the old generic icon after upgrade, run `sfltool resetbtm` to clear the macOS Background Tasks Management cache, then re-bootstrap. (`pager uninstall` also walks you to that hint on macOS.)

## [0.4.1] — 2026-05-19

Quick follow-up to 0.4.0 — sharper install URL, POSIX-portable installer, drop the dead-weight brew python install.

### Changed
- **Install URL switched to `raw.githubusercontent.com`.** Same one-liner shape (`curl … | sh`) but the new URL is `https://raw.githubusercontent.com/jawwadzafar/pager/main/install.sh`. Advantages over the GitHub Pages URL: zero Pages build delay between a commit and the installer reflecting it, and one canonical source of truth.
- **`install.sh` is now POSIX `sh`-compatible**, not bash. Shebang changed to `#!/bin/sh`. Dropped `set -o pipefail` (kept `set -eu`), replaced `$'\033…'` ANSI literals with explicit `printf '\033'` capture. Runs cleanly under `dash`, `bash`, `ash`, and zsh's `sh`. The one-liner now uses `| sh` instead of `| bash`.
- **Dropped `docs/install.sh` + the `make sync-installer` target + the "installers in sync" smoke test.** No longer needed — `raw.githubusercontent.com` always serves the canonical `install.sh` directly.
- **Dropped `brew install python@3.13`** from the macOS bootstrap step 2. Real-Mac test in 0.3.x showed Apple's `/usr/bin/python3` ends up being used by `bin/pager` anyway (Homebrew's `python@X` formulae don't reliably create the unversioned `/opt/homebrew/bin/python3` symlink). Step 2 is now just `brew install tmux libyaml` — ~75 MB lighter and faster on first install.
- Linted under `shellcheck -s sh install.sh` plus the existing bash-mode pass on the other shell files. Smoke tests: 23/23 pass.

### Notes
- For `PAGER_BRANCH=v0.4.1 …` to actually pin against a specific release, the maintainer needs to push annotated git tags. Tags are pushed alongside this release.

## [0.4.0] — 2026-05-19

The "now-it-feels-real" release: one-line installer, symmetric platform layout, cleaner repo top level.

### Added

**One-line installer** (`curl | bash`, à la Claude Code / rustup / homebrew)

```bash
curl -fsSL https://jawwadzafar.github.io/pager/install.sh | bash
```

- New `install.sh` at repo root + `docs/install.sh` (the Pages-served copy at `https://jawwadzafar.github.io/pager/install.sh`).
- Detects OS (`uname -s`), requires only `git`, clones into `$PAGER_HOME` (default `~/.pager`), then `exec`s the platform bootstrap. Idempotent on re-runs (does a `git pull --ff-only` then re-bootstrap).
- Env overrides: `PAGER_HOME`, `PAGER_BRANCH` (e.g. pin to a tag), `PAGER_REPO` (e.g. fork).
- Fresh-Mac and fresh-Linux failure modes are friendly: missing `git` prints the exact install command (`xcode-select --install` / `sudo apt-get install -y git`).
- `make sync-installer` keeps `install.sh` ↔ `docs/install.sh` byte-identical; new smoke test `installers in sync (root ↔ docs)` runs `diff -q` between them so a forgotten sync fails CI.

### Changed

**Symmetric platform layout** (`linux/` mirrors `macos/`)

```
pager/
├── install.sh              ← one-line entry point (NEW)
├── bootstrap.sh            ← thin OS-detecting shim (Linux | macOS)
├── linux/
│   ├── bootstrap.sh        ← was at repo root, now lives here
│   └── systemd/            ← was at repo root, now lives here
│       ├── pager.service
│       ├── pager-watch.service
│       └── pager-watch.timer
├── macos/
│   ├── bootstrap.sh        ← unchanged
│   └── launchd/com.pager.agent.plist.template
├── bin/pager
├── lib/{common,sudo}.sh
├── assets/
├── docs/                   ← website + install.sh copy
└── tests/, actions/, …
```

- Moved `bootstrap.sh` → `linux/bootstrap.sh`. Root `bootstrap.sh` is now an 8-line dispatcher that `exec`s the right one based on `uname -s`, so anyone with the old path in their muscle memory or in scripts still works.
- Moved `systemd/` → `linux/systemd/`. The unit templates with `__PAGER_ROOT__` substitution (added in 0.3.0) are unchanged in content.
- `Makefile` updated for the new paths: `service` and `watchdog` targets now `sed`-substitute `__PAGER_ROOT__` before installing the units (was a hard-coded path before).
- Smoke tests now also bash-syntax-check `install.sh`, `linux/bootstrap.sh`, `macos/bootstrap.sh`, and the installer sync. The "kill named session" / "watchdog restarts a dead session" pair now uses `pager kill` (the v0.2.2 verb that doesn't set the stop semaphore) — `pager stop` correctly stays-stopped now, which was breaking the old "expect watchdog to respawn" test.
- README install section rewritten: the `curl | bash` is now the primary install. The git-clone + per-OS bootstrap forms are kept as the "manual install" option. Expandable per-OS breakdowns preserved.
- Website hero install block: one big copy-able `curl | bash` line tagged "Linux + macOS" (warm amber pill, distinct from the Linux green and macOS blue tags from the per-OS cards). Walkthrough step 1 + the dedicated Install section also feature the one-liner; the per-OS cards just describe what each bootstrap does, with a "Or, the manual way" terminal block underneath. Added `Uninstall` block on the install page.

### Migration

- **From v0.3.x or earlier:** `cd ~/pager && git pull` will pick up the new layout. Your existing service / LaunchAgent paths still work because they point at `$__PAGER_ROOT/bin/pager`, which hasn't moved. To rename to `~/.pager` while you're at it: `pager uninstall && mv ~/pager ~/.pager && ~/.pager/install.sh`.
- **Fresh installs:** just `curl | bash`.

## [0.3.0] — 2026-05-19

### Added
- **`pager uninstall`** — the missing inverse of `bootstrap.sh`. Stops the service / LaunchAgent, removes the `~/.local/bin/pager` symlink, and strips the pager `.env` auto-source line from `~/.bashrc` / `~/.zshrc` / `~/.zprofile` / `~/.profile` (with a timestamped backup of each rc file). Deliberately leaves the repo and your `.env` in place — `rm -rf $PAGER_ROOT` is a separate, explicit step you do yourself. Pass `-y` / `--yes` to skip the confirmation prompt. OS-aware: `launchctl bootout` on macOS (covers the new `com.pager.agent` *and* the legacy `com.pager.session` / `com.pager.watch` labels for old installs), `systemctl --user stop+disable` on Linux.
- The macOS uninstall path also prints the optional `sfltool resetbtm` hint for clearing any stale Login Items entries and notification stacks.

### Changed
- **Install path is now agnostic of clone location, on both Linux and macOS.** Previously both the macOS LaunchAgent plist and the Linux systemd units hard-coded the install path (`__USER_HOME__/pager/...` on Mac, `%h/pager/...` on Linux), so a clone at any other path (e.g. `~/.pager`, `~/code/pager`) would silently produce broken service files. Replaced with a `__PAGER_ROOT__` placeholder that both bootstraps substitute at install time. The macOS LaunchAgent and the Linux systemd units now also export `PAGER_ROOT` so spawned children inherit the path.
- Linux bootstrap step 7 changed from a flat `install -m 644 …` of the three unit files to a `render_unit` function that sed-substitutes `__PAGER_ROOT__` first.
- The shell-rc auto-source line that bootstrap writes (`~/.zshrc` on macOS, `~/.bashrc` on Linux) now contains the literal `$__PAGER_ROOT` path of the current install instead of the hard-coded `$HOME/pager/.env` form. Idempotency check still matches any `pager/.env` shape, so re-running bootstrap from a new location is safe.
- README now recommends cloning to **`~/.pager`** (hidden, keeps `$HOME` tidy) instead of `~/pager`, with an explicit note that any clone path works. Old installs at `~/pager` continue to work — just re-run bootstrap from there.

### Notes
- Migrating from `~/pager` to `~/.pager`: easiest path is `pager uninstall` (from the current install), then `mv ~/pager ~/.pager`, then `~/.pager/macos/bootstrap.sh` (or `~/.pager/bootstrap.sh` on Linux). Bootstrap rewrites the LaunchAgent plist and shell-rc line with the new path.

## [0.2.3] — 2026-05-19

### Changed
- **One LaunchAgent instead of two on macOS.** Previously installed `com.pager.session.plist` + `com.pager.watch.plist`, which showed up as two separate rows in System Settings → Login Items & Extensions and triggered two "Background item added" notifications. Replaced with a single `com.pager.agent.plist` that runs `pager watchdog claude` at `RunAtLoad=true` + `StartInterval=70`. The watchdog's existing "session missing → spawn it" code path handles initial startup; subsequent ticks check health. Same behavior, half the system noise.
- macOS bootstrap step 10 now migrates any old two-agent install in place: it `bootout`s the old `com.pager.session` / `com.pager.watch`, removes their plist files, then installs the new `com.pager.agent`.
- `bin/pager`'s OS-aware paths (`cmd_doctor`, `cmd_help`, `_watchdog_disable`, `_watchdog_enable`) updated to reference `com.pager.agent`. `cmd_doctor` also warns if a stale `com.pager.session` or `com.pager.watch` plist is still on disk, prompting a re-bootstrap to migrate.
- macos/README.md, CHANGELOG, and the bootstrap verify banner all updated to match.

### Notes
- This is a clean migration — re-run `./macos/bootstrap.sh` on the Mac and the old agents are torn down before the new one is installed. No manual cleanup needed.
- The combined agent also has a side benefit on TCC: only one launchd-spawned context interacts with the tmux server at a time (the watchdog *is* the spawner of the session), which can reduce the cross-context TCC prompts macOS fires for "X would like to access data from other apps."

## [0.2.2] — 2026-05-19

Follow-up to 0.2.1 — adds `kill` and `restart` so users have the full set of session-control verbs, not just `stop` (which now also pauses the watchdog).

### Added
- **`pager kill [name|--all]`** — kills a session WITHOUT setting the stop semaphore. The watchdog will respawn at the next tick. This is the v0.2.0 `stop` behavior, now under its own verb. Use it when you want to force a fresh `claude` process and let the watchdog bring it back automatically.
- **`pager restart [name|--all]`** — kill + start, immediately. Doesn't wait for the watchdog. `--all` additionally bounces the watchdog process (`launchctl bootout`/`bootstrap` on macOS, `systemctl --user stop`/`start pager-watch.timer` on Linux) — useful when the watchdog itself is in a weird state. Always clears the stop semaphore.

### Mental model
- `start` — bring it up. Clears semaphore.
- `stop` — bring it down and keep it down. Sets semaphore.
- `kill` — bring it down, but the watchdog will resurrect it. Doesn't touch semaphore.
- `restart` — kick the session right now. Clears semaphore. `--all` also bounces the watchdog.

## [0.2.1] — 2026-05-19

Hotfix released a few hours after 0.2.0 based on first real-Mac feedback.

### Fixed
- **`pager stop` is now persistent.** Previously, `pager stop` killed the session but the watchdog fired ~70s later, saw the session was gone, and respawned it — `stop` was effectively a no-op short of rebooting. Now `pager stop` touches a `logs/.stopped` semaphore file that the watchdog checks BEFORE making any tmux calls; if present, the watchdog logs a `manually-stopped` row and exits cleanly. `pager start` removes the semaphore and resumes.
- This also fixes a macOS-specific pain: while pager is stopped, the watchdog no longer makes tmux calls, so the macOS App Management TCC prompt (`"tmux" would like to access data from other apps`) stops firing every 70 seconds.

### Added
- **`pager stop --all`** now also unloads the watchdog process itself (`launchctl bootout` on macOS, `systemctl --user stop pager-watch.timer` on Linux) — for "I want pager fully quiet, no ticks at all." Plain `pager stop` still pauses via the semaphore (lighter touch).
- macos/README.md gained a dedicated section explaining the tmux TCC prompt, how to grant the permission permanently in System Settings, and the `pager stop` semantics as a way to silence pager without uninstalling.

## [0.2.0] — 2026-05-19

macOS support — pager now runs natively on **macOS Tahoe 26** and **Sequoia 15**, both Apple Silicon and Intel.

### Added

**macOS bootstrap**
- New `macos/bootstrap.sh` — idempotent installer that mirrors the Linux bootstrap step-for-step. Detects arch (`arm64` → `/opt/homebrew`, `x86_64` → `/usr/local`), installs Homebrew if missing, then `brew install tmux libyaml python@3.13` and (optional) `brew install hudochenkov/sshpass/sshpass`.
- `pyyaml` installed via `python3 -m pip install --user --break-system-packages` with a cascade fallback to plain `--user` for older pip — needed because Homebrew's `pyyaml` formula was disabled 2024-10-06 and modern Homebrew Python enforces PEP 668.
- Wires `~/.zprofile` (`brew shellenv` + `~/.local/bin` PATH) and `~/.zshrc` (pager `.env` auto-source) instead of `~/.bashrc` / `~/.profile`.
- `macos/launchd/com.pager.session.plist.template` + `macos/launchd/com.pager.watch.plist.template` — LaunchAgents replacing `pager.service` + `pager-watch.timer`. Templates substitute `__USER_HOME__` and `__BREW_BIN__` at install time (launchd doesn't expand `$HOME`).
- Modern `launchctl bootstrap gui/$(id -u)` + `bootout` syntax for load/unload (not the legacy `load`/`unload`).
- Session agent uses `KeepAlive { SuccessfulExit = false }` — restart on failure only, matching the Linux `Restart=on-failure` semantics.
- Watch agent uses `StartInterval=70` to mirror the existing systemd timer cadence.

**`bin/pager` cross-platform**
- New `PAGER_OS` runtime detection (`mac` or `linux`) with branching in `cmd_doctor` (`Services` section uses `launchctl print gui/$UID/...` on macOS) and `cmd_help` (`Service` block shows the right command names per OS).
- `cmd_doctor` linger check is replaced on macOS with an informational `autostart: at login (LaunchAgent — no boot-time equivalent on macOS)` line.
- New portable helpers `file_mode()` (replaces `stat -c '%a'`) and `date_to_epoch()` (replaces `date -d`) built on `python3`, fixing silent BSD-coreutils failures on macOS.

**Docs**
- Root `README.md` install section split into **Linux (`apt`)** and **macOS (`brew`)** with two one-command install lines, expandable per-OS step-by-step breakdowns, and a platform badge update.
- New `macos/README.md` covering: supported versions, what the bootstrap does, **macOS permissions you'll be asked for** (Mac password, Xcode CLT, Background Items toggle, firewall apps), what to do if a prompt is denied, login-vs-boot autostart caveat, common operations, uninstall recipe.
- Website (`docs/index.html` + `docs/style.css`) refreshed: cross-platform tagline, two-OS install card grid, OS pill badges (Linux green / macOS blue), retro CRT touches — phosphor glow on the headline, subtle scanline + vignette overlay on the hero, glow on `✓` marks, drop-shadow on the new flow illustration.
- New SVG `assets/flow.svg` (+ `flow-dark.svg`) — companion to the pager logo, showing the full flow: CRT monitor → signal waves → phone, in the same green-screen + chunky-bezel aesthetic. Shipped to `docs/` for the website too.

### Changed

- Platform badge in README now reads `Linux | macOS`.
- Diagram in README + website: `Linux box` → `Your machine`.
- Feature cards on the website: explicit "Linux + macOS" entry; service/watchdog cards mention both backends.

### Notes

- macOS autostart is at **login**, not at boot — LaunchAgent semantics. For closer-to-linger behavior, enable macOS auto-login (incompatible with FileVault). A LaunchDaemon for true boot-time start is intentionally out of scope.
- `~/Library/LaunchAgents/com.pager.*.plist` ownership and `chmod 644` are required for launchctl to load them; bootstrap enforces this.
- The macOS bootstrap pulls `python@3.13` for forward-looking pip support but the actual `python3` on PATH may stay as Apple's CLT 3.9 (Homebrew doesn't always create the unversioned symlink). pyyaml is installed for whichever `python3` is on PATH, so `bin/pager`'s inline yaml parsing stays self-consistent.

## [0.1.0] — 2026-05-19

Initial public release.

### Added

**Core**
- Single binary `bin/pager` with subcommands: `start`, `attach`, `stop`,
  `status`, `url`, `ssh`, `run`, `watchdog`, `doctor` (alias `check`), `help`.
- `claude --remote-control` autostart via `systemd/pager.service`
  (user-level unit, oneshot + RemainAfterExit).
- `systemd/pager-watch.service` + `.timer` — 60-second self-healing
  watchdog. Detects whether the Claude process inside a session is alive
  and restarts it if dead. Appends a row to `logs/watch.csv` every tick
  so post-mortems are trivial.
- **`pager doctor`** — one-command health report. Walks deps, PATH
  resolution (catches the `/usr/bin/pager` BSD-pager / less alias shadow),
  `.env` perms, Claude Code workspace trust flag, both services, linger,
  watchdog tick freshness, running sessions. Exit non-zero if anything is
  broken, with a one-line fix hint on every failure. Run this first when
  something looks off.
- **Enriched `pager status`** — `NAME | CLAUDE | AGE | REMOTE CONTROL URL`
  table for "what's running and where do I jump in".

**Install & ops**
- **`bootstrap.sh`** — idempotent one-command install. Installs apt
  prereqs, creates `.env` from template (chmod 600, gitignored), wires
  `~/.bashrc` to auto-source `.env`, installs `pager` as a real user-PATH
  binary at `~/.local/bin/pager` (ahead of `/usr/bin/pager` on every
  shell type), pre-trusts `$HOME` in `~/.claude.json` so the autostart
  session isn't blocked by Claude Code's first-run "Trust this folder?"
  prompt, installs `pager.service` + `pager-watch.timer`, enables linger,
  starts the service, prints the live phone URL.
- **`Makefile`** — `install`, `service`, `watchdog`, `test`, `lint`,
  `check`, `bootstrap`, `status`, `url`, `logs`, `version`, `help`.
- **`lib/sudo.sh`** — bundled askpass helper. Reads `SUDO_PASSWORD` from
  `.env` and exports `SUDO_ASKPASS` so `sudo -A` runs unattended; falls
  back to interactive `sudo` if `SUDO_PASSWORD` is unset.

**Fleet / SSH**
- `inventory.yaml` schema for SSH host metadata; passwords referenced
  by env-var name only, never literal.
- `actions/uptime.sh`, `actions/restart.sh` — example remote action
  scripts streamed over SSH by `pager run`.

**Tests & quality**
- `tests/smoke.sh` — 20 checks, fully sandboxed (private tmux server +
  stub `claude` binary). Survives running inside a real tmux session
  (`$TMUX` / `$TMUX_PANE` unset, pre-existing `logs/watch.csv`
  preserved + restored). Run via `make check` (lint + tests).
- `.github/ISSUE_TEMPLATE/*` + `.github/PULL_REQUEST_TEMPLATE.md` —
  bug template leads with `pager doctor` output, PR template gates on
  `make check` + doctor green.

**Branding & docs**
- `assets/logo.svg` + `assets/logo-dark.svg` — vector logo (pager device,
  signal waves, wordmark). README auto-switches via
  `<picture media="(prefers-color-scheme: dark)">`.
- **Website** at [jawwadzafar.github.io/pager](https://jawwadzafar.github.io/pager/)
  — single-page pitch + quick-start. Lives in `docs/`, hand-rolled
  HTML/CSS, no build step.
- `README.md` — 60-second phone walkthrough, command reference, install
  modes, watchdog explainer, SSH setup, orientation notes for new Claude
  sessions.
- `CLAUDE.md` — context for future Claude Code sessions resuming work
  in this repo: hard rules (no secrets in chat, no passphrased SSH keys
  for headless, idempotency), how `lib/sudo.sh` works, the trust-prompt
  trap, where new things go.
- `CONTRIBUTING.md` — style + how-to-add-a-subcommand.
- MIT license.

### Security
- `.env` is the only place secrets live; chmod 600 and gitignored.
- No literal credentials in any committed file (verified by the
  `.env.example is template-only` smoke test).
- SSH key passphrase removal is recommended (required for the headless
  flow); bootstrap reports the state and prints the exact fix command
  rather than bypassing the user's passphrase interactively.
- Example hosts use `<box-ip-or-dns>` placeholder rather than any
  IP-looking string, so readers don't mistake an example for a real host.

[Unreleased]: https://github.com/jawwadzafar/pager/compare/v0.6.9...HEAD
[0.6.9]: https://github.com/jawwadzafar/pager/releases/tag/v0.6.9
[0.6.8]: https://github.com/jawwadzafar/pager/releases/tag/v0.6.8
[0.6.7]: https://github.com/jawwadzafar/pager/releases/tag/v0.6.7
[0.6.6]: https://github.com/jawwadzafar/pager/releases/tag/v0.6.6
[0.6.5]: https://github.com/jawwadzafar/pager/releases/tag/v0.6.5
[0.6.4]: https://github.com/jawwadzafar/pager/releases/tag/v0.6.4
[0.6.3]: https://github.com/jawwadzafar/pager/releases/tag/v0.6.3
[0.6.2]: https://github.com/jawwadzafar/pager/releases/tag/v0.6.2
[0.6.1]: https://github.com/jawwadzafar/pager/releases/tag/v0.6.1
[0.6.0]: https://github.com/jawwadzafar/pager/releases/tag/v0.6.0
[0.5.7]: https://github.com/jawwadzafar/pager/releases/tag/v0.5.7
[0.5.6]: https://github.com/jawwadzafar/pager/releases/tag/v0.5.6
[0.5.5]: https://github.com/jawwadzafar/pager/releases/tag/v0.5.5
[0.5.4]: https://github.com/jawwadzafar/pager/releases/tag/v0.5.4
[0.5.3]: https://github.com/jawwadzafar/pager/releases/tag/v0.5.3
[0.5.2]: https://github.com/jawwadzafar/pager/releases/tag/v0.5.2
[0.5.1]: https://github.com/jawwadzafar/pager/releases/tag/v0.5.1
[0.5.0]: https://github.com/jawwadzafar/pager/releases/tag/v0.5.0
[0.4.1]: https://github.com/jawwadzafar/pager/releases/tag/v0.4.1
[0.4.0]: https://github.com/jawwadzafar/pager/releases/tag/v0.4.0
[0.3.0]: https://github.com/jawwadzafar/pager/releases/tag/v0.3.0
[0.2.3]: https://github.com/jawwadzafar/pager/releases/tag/v0.2.3
[0.2.2]: https://github.com/jawwadzafar/pager/releases/tag/v0.2.2
[0.2.1]: https://github.com/jawwadzafar/pager/releases/tag/v0.2.1
[0.2.0]: https://github.com/jawwadzafar/pager/releases/tag/v0.2.0
[0.1.0]: https://github.com/jawwadzafar/pager/releases/tag/v0.1.0
