# Contributing to pager

Small project, low ceremony. Issues and pull requests welcome.

## Quickstart for hacking

```bash
git clone https://github.com/jawwadzafar/pager.git
cd pager
make help          # see all targets
make check         # shellcheck + smoke tests
```

## Project layout

- `bin/pager` — the only binary. Single bash file, ~210 lines, dispatcher + subcommands.
- `lib/sudo.sh` — bundled askpass helper. Sourced from scripts that need root.
- `bootstrap.sh` — idempotent fresh-machine installer.
- `systemd/pager.service` — user-level systemd unit.
- `actions/<verb>.sh` — examples of remote actions run via `pager run`.
- `tests/smoke.sh` — exercises every subcommand. Run with `make test`.
- `Makefile` — install / uninstall / service / test / lint / check / bootstrap.

## Adding a subcommand

1. Add a `cmd_<verb>` function in `bin/pager`.
2. Add a case entry in the dispatch block at the bottom of the file.
3. Add a line in `cmd_help` so it shows up.
4. Add tests in `tests/smoke.sh` that cover the success path and a clean error.
5. Update `README.md` quick reference.

## Adding a remote action

`actions/<verb>.sh` runs on the **remote** host via `bash -s`. Pass args:

```bash
pager run <alias> myverb -- arg1 arg2
# becomes: ssh <alias> "bash -s -- arg1 arg2" < actions/myverb.sh
```

Keep actions short and idempotent. Document what they assume about the remote host (sudo? specific packages?).

## Style

- `set -euo pipefail` at the top of every script.
- `shellcheck` clean (`make lint`). Use `# shellcheck disable=SCxxxx` with a comment when a warning is intentional.
- Bash, not zsh. Target Bash 4+ (Ubuntu 20.04 and up).
- No external dependencies the bootstrap doesn't `apt install`. If you need a new tool, add it to bootstrap.sh's apt install line.
- User-facing strings (`echo`, `warn`, `err`) should not leak secrets. If a value comes from `.env`, refer to its name, never its content.

## Testing

`make test` runs `tests/smoke.sh`, which uses a private tmux server (separate socket) and a stub `claude` binary, so it doesn't interfere with real sessions. Run it locally before sending a PR.

When adding tests, prefer the `check` / `check_output` helpers in `smoke.sh` — they keep the output uniform.

## Security

- **Never commit `.env`.** It's gitignored. Confirm with `git check-ignore .env` before pushing.
- **Don't echo secret values to chat, logs, or stderr.** Use boolean leak checks (`[ -n "$VAR" ]`, `grep -q '^KEY=' file`).
- The bundled SSH key advice removes the passphrase for headless flow. If you have a better design that keeps a passphrase but still works for autostart, open an issue first — that's a major change.

## Pull requests

- Squash-merge friendly: one logical change per PR.
- CI must pass. Watch the Actions tab.
- Update CHANGELOG.md under `## [Unreleased]` with a one-line note.
- Don't bump the version yourself — the maintainer cuts releases.

## License

MIT. By contributing you agree your code is offered under the same license.
