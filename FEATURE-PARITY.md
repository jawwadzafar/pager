# Feature parity across platforms

**Short version:** Linux and macOS share the full feature set (same `bin/pager`
bash binary; only the autostart layer differs — systemd vs launchd). Windows
is a deliberate subset implemented in PowerShell (`bin/pager.ps1`). If a
feature exists on Windows, it exists on Linux/macOS too. The reverse is not
true.

This file is the source of truth for what works where. The
[CHANGELOG](CHANGELOG.md) is the source of truth for *when* each piece landed.

## Why a subset on Windows

Three constraints shape the Windows port:

1. **No tmux.** PowerShell doesn't have an equivalent persistent-session host
   that ships in-box. `Start-Process -WindowStyle Hidden` gives claude a
   real TTY in a hidden console, but the screen buffer can't be tailed to
   a file without stripping the TTY (which is what made claude bail in
   v0.7.0-alpha → -alpha-2).
2. **No user-timer parity.** Linux has systemd user timers; macOS has
   launchd `StartInterval`. Windows Scheduled Tasks support repeat triggers
   but the orchestration model is different enough that the bash watchdog
   doesn't translate one-to-one.
3. **Pragmatism.** The 80%-use-case on Windows is *"start claude, get the
   phone URL, pair from my phone, walk away"*. That's the slice we ship
   solidly. Power features (`attach`, `ssh`, `run`) are Linux/Mac strengths
   and not worth half-porting.

## What "Linux" and "macOS" share

Both run `bin/pager` (bash, ~1300 lines). Same commands, same flags, same
output. Differences are entirely in the autostart layer:

| Aspect | Linux | macOS |
|---|---|---|
| Persistent terminal session | tmux | tmux |
| Autostart unit | `systemd --user` (`pager.service` + `pager-watch.timer`) | `launchd` (`LaunchAgents/com.pager.session.plist` + watch agent) |
| Linger / login-independence | `loginctl enable-linger` | LaunchAgent runs at user login; no linger equivalent needed |
| Watchdog | 60s user-timer running `pager watchdog` | launchd watch agent running `pager watchdog` on `StartInterval` |
| Permission prompts | none typically | macOS may prompt for Background Items the first time the LaunchAgent loads |

Everything below the autostart layer is identical.

## Full feature matrix

✓ = supported · ❌ = not implemented · ⚠️ = different/degraded behavior

| Command | Linux | macOS | Windows | Notes |
|---|---|---|---|---|
| `start [name] [--cwd DIR]` | ✓ | ✓ | ✓ | Linux/Mac: tmux. Windows: hidden console (alpha-3+). |
| `stop [name]` | ✓ | ✓ | ✓ | Linux/Mac stop also writes a `.stopped` semaphore so the watchdog pauses; Windows has no watchdog so no semaphore. |
| `kill [name\|--all]` | ✓ hard-kill, watchdog respawns | ✓ same | ⚠️ alias for `stop` | No semantic difference on Windows because there's no watchdog to outrun. |
| `restart [name\|--all]` | ✓ | ✓ | ❌ | Use `pager stop && pager start` on Windows. |
| `status` / `ls` | ✓ | ✓ | ✓ | |
| `url [name]` | ✓ greps `logs/<name>.log` | ✓ same | ✓ scrapes hidden-console buffer via `AttachConsole` + `ReadConsoleOutputCharacter`, then caches | |
| `attach [name]` | ✓ full PTY via tmux | ✓ same | ❌ | Use `pager logs` for a read-only tail (Linux/Mac) or `wsl` (Windows). |
| `logs [name]` | (effectively `tmux pipe-pane` tail) | (same) | ⚠️ prints "install WSL2 for full log tailing" | Windows alpha-3 dropped log capture entirely so claude keeps its TTY. |
| `trust [PATH ...]` | ✓ | ✓ | ✓ | All three accept `--check` and `--reset`. |
| `trust --repair` | ❌ not needed | ❌ not needed | ✓ alpha-4 | Windows-only because the bugs it repairs are Windows-only (splat-as-chars, slash-form mismatch, duplicate-key race in `~/.claude.json`). |
| `doctor` / `check` | ✓ | ✓ | ✓ | |
| `doctor --fix` | ✓ + `-y` modifier for macOS TCC prompts | ✓ same | ✓ alpha-4 (runs `trust --repair`) | Linux/Mac `--fix` handles many cases (linger, trust, perms, missing units, etc.); Windows `--fix` currently only repairs trust state. |
| `autostart enable\|disable\|status` | ✓ systemd user | ✓ launchd | ✓ Scheduled Task | |
| `watchdog [name]` | ✓ one-tick health check, appends to `logs/watch.csv` | ✓ same | ❌ | Windows relies on Scheduled Task `RestartInterval=2m, RestartCount=3`. If claude crashes 4× in a row, session stays dead until next login. |
| `info` | ✓ | ✓ | ✓ | |
| `uninstall [-y]` | ✓ | ✓ | ✓ | |
| `ssh <alias> [cmd]` | ✓ inventory.yaml + SSH multiplexer | ✓ same | ❌ | Python + pyyaml are installed by Windows bootstrap so it's a small follow-up. |
| `run <alias> <action> [-- args]` | ✓ runs `actions/*.sh` over SSH | ✓ same | ❌ | Same follow-up as `ssh`. |

## What "out of the box" means per platform

The 80%-case install on each platform gets you:

- **Linux**: install → `pager start` runs at every boot (systemd + linger), `pager url` gives the phone URL, `pager attach` for live debugging, watchdog auto-restarts on crash, full SSH inventory ready.
- **macOS**: same as Linux except launchd instead of systemd, and the first launch may show one macOS "Background Items added" notification.
- **Windows**: install → `pager start` runs at user login (Scheduled Task), `pager url` gives the phone URL. That's the loop. No live attach, no watchdog beyond Scheduled Task restarts, no SSH inventory. If claude misbehaves: `pager doctor --fix` then `pager stop && pager start`.

## Roadmap implied by these gaps

Tracked loosely; not a commitment. Priority order based on which gaps users
actually feel:

- **v0.8 — Windows ConPTY-backed sessions.** Gives `attach` and real `logs`
  on Windows; the hidden-console alpha-3 trick goes away. Same release
  likely brings a real `watchdog` (60s Scheduled Task trigger calling
  `pager watchdog`, parity with the user-timer model on Linux).
- **v0.9 — `restart` on Windows.** Trivial once stop+start semantics settle
  alongside the new watchdog.
- **v0.9+ — `ssh` / `run` ported to PowerShell.** Inventory parsing is
  already a Python script that runs the same everywhere; mostly plumbing.
- **No plan to port `trust --repair` to Linux/macOS.** The three bug classes
  it fixes are Windows-PowerShell-specific. The bash trust path doesn't
  produce char-splat damage, doesn't have the backslash/forward-slash
  ambiguity, and `~/.claude.json` doesn't end up with duplicate keys after
  claude restarts on those platforms. (If that changes, this paragraph is
  the place to update.)

## When you hit a gap

1. Run `pager doctor` on the affected platform — it reports the most common
   "thing missing" cases with explicit fix hints.
2. Check this file (and the platform's `<platform>/README.md`) for whether
   the gap is intentional vs. a bug.
3. If intentional and you want the feature, the right fix is usually
   "install WSL2 + the Linux installer" on Windows, or just running the
   bash command directly on Linux/Mac.
4. If unintentional, that's a bug — open an issue with `pager doctor`
   output + platform + a one-line repro.
