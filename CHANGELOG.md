# Changelog

All notable changes to **pager** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/jawwadzafar/pager/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/jawwadzafar/pager/releases/tag/v0.4.0
[0.3.0]: https://github.com/jawwadzafar/pager/releases/tag/v0.3.0
[0.2.3]: https://github.com/jawwadzafar/pager/releases/tag/v0.2.3
[0.2.2]: https://github.com/jawwadzafar/pager/releases/tag/v0.2.2
[0.2.1]: https://github.com/jawwadzafar/pager/releases/tag/v0.2.1
[0.2.0]: https://github.com/jawwadzafar/pager/releases/tag/v0.2.0
[0.1.0]: https://github.com/jawwadzafar/pager/releases/tag/v0.1.0
