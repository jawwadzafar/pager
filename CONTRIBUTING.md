# Contributing to pager

Small project, low ceremony. PRs welcome.

## Quickstart

```bash
git clone https://github.com/jawwadzafar/pager.git
cd pager
make help          # see all targets
make check         # shellcheck + smoke tests  (must stay green)
```

## Project layout

```
pager/
├── bin/pager                       # the single binary. Bash, dispatcher + subcommands.
├── lib/
│   ├── sudo.sh                     # askpass helper for scripts that need root
│   └── autostart.sh                # OS-aware enable/disable/status for LaunchAgent + systemd unit
├── bootstrap.sh                    # thin OS-detecting dispatcher (back-compat entry point)
├── install.sh                      # curl|sh entry point. POSIX sh — must stay ASCII-only.
├── linux/
│   ├── bootstrap.sh                # Debian/Ubuntu install flow
│   └── systemd/{pager.service,pager-watch.service,pager-watch.timer}
├── macos/
│   ├── bootstrap.sh                # macOS install flow (Tahoe 26 / Sequoia 15)
│   ├── launchd/com.pager.agent.plist.template
│   ├── pager.app/                  # bundle skeleton (Info.plist + Resources + MacOS shim)
│   └── README.md                   # macOS-specific notes (TCC prompts, autostart, etc.)
├── actions/                        # remote action scripts run via `pager run`
├── assets/                         # logo + flow SVGs, icon generator scripts
├── docs/                           # GitHub Pages website (jawwadzafar.github.io/pager)
├── tests/smoke.sh                  # 23 sandboxed checks. `make test`.
├── Makefile                        # install / uninstall / service / test / lint / check / etc.
├── CHANGELOG.md                    # Keep a Changelog format
├── CODE_OF_CONDUCT.md
└── LICENSE                         # MIT
```

## Open opportunities

Real, well-scoped places where a PR would land cleanly:

- **Linux distro support** beyond Debian/Ubuntu. `linux/bootstrap.sh` currently fails fast for `dnf` / `pacman` / `zypper` / `apk`. Add a per-PM branch in step 1 + a package-name mapping table in a new `linux/packages.sh` lib. Touch points are clearly named in the error message the bootstrap prints today.
- **Homebrew formula** for `pager`. Either submit to homebrew-core or maintain a tap. The .app bundle work in `macos/` is already there; you'd just need a formula that calls `install.sh`.
- **Cross-platform real-time log viewer.** Currently `pager logs` is a thin `tail -F`. A nicer version could pretty-print, colorize, and show watch.csv rows interleaved.
- **Per-session env overrides** via `pager start --env KEY=VAL …`.
- **macOS Login Items icon investigation.** See [CHANGELOG v0.5.7](CHANGELOG.md#057--2026-05-19) for the rabbit hole — the icon never rendered despite 6 attempts. Almost certainly requires a real Apple Developer ID. If you have one, signing the bundle with a real Team ID may finally fix it.
- **macOS smoke tests.** `tests/smoke.sh` is Linux-only today. The macOS side has been entirely manually verified, which is a gap.

Open an issue first for anything that would touch >1 file or change behavior; small fixes can go straight to PR.

## Adding a subcommand

1. Add a `cmd_<verb>` function in `bin/pager`.
2. Add a case entry in the dispatch block at the bottom of the file.
3. Add a line under `cmd_help` so it shows up in `pager --help`.
4. Add tests in `tests/smoke.sh` covering the success path and at least one clean error.
5. Update README quick reference.

## Adding a remote action

`actions/<verb>.sh` runs on the **remote** host via `bash -s`. Pass args:

```bash
pager run <alias> myverb -- arg1 arg2
# becomes:  ssh <alias> "bash -s -- arg1 arg2"  < actions/myverb.sh
```

Keep actions short and idempotent. Document what they assume about the remote host (sudo? specific packages?). They can't see local files or env beyond what's passed via args.

## Style

- `set -euo pipefail` at the top of every bash script. `set -eu` for POSIX `sh` scripts (`install.sh`, the `pager.app` launcher).
- `shellcheck` clean (`make lint`). Use `# shellcheck disable=SCxxxx` with a one-line reason when a finding is intentional.
- Bash 4+ syntax fine for bash files. POSIX-only for `#!/bin/sh` files — and **ASCII-only** there too (see v0.5.2 for the macOS `/bin/sh` Unicode regression that motivated this rule).
- No external runtime deps the bootstrap doesn't install. Adding a new tool? It goes in the platform bootstrap's package list and ideally has a documented fallback if absent.
- User-facing strings (`echo`, `warn`, `err`) should not leak secrets. If a value comes from `.env`, refer to its name (`$GH_TOKEN`), never its content. Boolean leak-checks only: `[ -n "$VAR" ]`, `grep -q '^KEY=' file`.

## Testing

`make test` runs `tests/smoke.sh`, which uses a private tmux server (separate socket via `TMUX_TMPDIR`) and a stub `claude` binary, so it doesn't interfere with real sessions or the LaunchAgent running on your dev box. Run it before every PR.

When adding tests, prefer the `check` / `check_output` helpers — they keep output uniform.

## Pull requests

- One logical change per PR. Squash-merge friendly.
- `make check` must pass locally. The smoke test suite is the regression guard.
- Update `CHANGELOG.md` under `## [Unreleased]` with a one-line note for user-visible behavior changes.
- Don't bump the version yourself — the maintainer cuts releases.

## Security

- **Never commit `.env`.** It's gitignored. Confirm with `git check-ignore .env` before pushing.
- **Don't echo secret values to chat, logs, or stderr.** Use boolean leak checks only.
- The SSH-key passphrase advice removes the passphrase for headless flow. If you have a better design that keeps a passphrase AND works for autostart, open an issue first — that's a structural change.

## License

MIT. By contributing you agree your code is offered under the same license, and you've read the [Code of Conduct](CODE_OF_CONDUCT.md).
