# Changelog

All notable changes to **pager** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/jawwadzafar/pager/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/jawwadzafar/pager/releases/tag/v0.1.0
