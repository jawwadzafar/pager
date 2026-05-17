# CLAUDE.md — context for resuming work in `pager`

This file orients a future Claude Code session that lands inside this repo. **Read this first**, then `README.md` for the quick reference.

## What this project is

A self-contained toolkit that turns any always-on Linux box into a remote-controllable Claude Code rig. Background tmux session + `claude --remote-control`, so any phone signed into the same claude.ai account can drive the session.

Companion to that: a tiny inventory-driven SSH helper (`pager ssh`, `pager run`) for running pager tasks against your fleet from inside that always-on Claude session.

Open source under MIT. Designed to be cloned and used on any Ubuntu/Debian box without external dependencies.

## Hard rules

1. **Never echo, cat, or print** `SUDO_PASSWORD`, `GH_TOKEN`, SSH passphrases, or any `*_SSH_PASS` value to chat — not even partial. Use boolean leak checks only (`[ -n "$VAR" ]`, `grep -q '^KEY=' file`). Same applies in error messages.
2. **For headless flows the SSH key must have no passphrase.** ssh-agent isn't used. If the user has a passphrased key, print the exact `ssh-keygen -p` one-liner to remove it — never bypass interactively.
3. **`.env` lives only in `~/pager/.env`** (chmod 600, gitignored). Do not commit it. Do not add a second copy at `~/.env` or elsewhere. The repo's `.env.example` is the canonical template.
4. **Never add `Co-Authored-By: Claude`** to git commits in this user's repos.
5. **Idempotency required** for any setup script. `bootstrap.sh` is the model: detect by functional pattern, not marker comment; re-runs must be no-ops if state is already correct.

## How sudo works here

The bundled helper is `lib/sudo.sh`. Source it from any script that needs root, then use `sudo -A`:

```bash
__PAGER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$__PAGER_ROOT/lib/sudo.sh"
sudo -A apt-get install -y …
```

Behavior:
- If `SUDO_PASSWORD` exists in `~/pager/.env`, the helper writes a temp askpass script (chmod 700) and exports `SUDO_ASKPASS`. `sudo -A` runs unattended. The temp file is cleaned up on shell EXIT via `trap`.
- If `SUDO_PASSWORD` is unset, `SUDO_ASKPASS` is not exported and `sudo -A` falls back to the normal interactive prompt. Both modes are valid; the script doesn't need to branch.

**No external dependency.** Don't reach into other repos (`~/hardware`, anywhere else) for sudo helpers — `lib/sudo.sh` here is the only one.

## The Claude Code trust-prompt trap (and the fix)

First time `claude` runs in a workspace, it shows a blocking "Trust this folder?" prompt before going interactive. **Critical for autostart:** until that prompt is dismissed (`1` + Enter), the session sits idle and `--remote-control` never registers a URL with claude.ai.

`bootstrap.sh` step 5 pre-sets the trust flag in `~/.claude.json`:

```json
{
  "projects": {
    "/home/<user>": {
      "hasTrustDialogAccepted": true,
      "hasCompletedProjectOnboarding": true
    }
  }
}
```

So when `pager.service` starts on boot, the spawned `claude --remote-control claude` goes straight to the prompt and the URL appears within ~5 seconds.

If you're seeing a session that never produces a URL after boot, the trust flag is the first thing to check:

```bash
python3 -c "import json; d=json.load(open('$HOME/.claude.json')); print(d['projects']['$HOME']['hasTrustDialogAccepted'])"
```

If `False`, re-run `bootstrap.sh` (it's idempotent and fixes this) or set it manually.

## How `pager start` works

`pager start [session]` launches `claude --remote-control <session> --dangerously-skip-permissions` inside a detached tmux session. The pane is mirrored to `~/pager/logs/<session>.log` via `tmux pipe-pane`. It's the entry point for `~/.config/systemd/user/pager.service` (oneshot, RemainAfterExit), which the systemd unit invokes as `ExecStart=%h/pager/bin/pager start claude`.

Notes:
- Linger is enabled (`loginctl enable-linger`), so the service starts at boot before any login.
- `pager` sources `$PAGER_ROOT/.env` at the top of every invocation, so the spawned `claude` process has `GH_TOKEN` and other env vars available.
- The session is named `claude` by default. The dispatcher refuses to clobber an existing session.
- `--remote-control` registers the session with claude.ai. The URL `https://claude.ai/code/session_…` appears in the pane. Fetch it without attaching via `pager url [name|--all]`.
- To start a session WITHOUT remote-control (e.g. air-gapped, no claude.ai), set `PAGER_NO_REMOTE=1`.

To inspect: `pager status` or `tmux ls`. Live transcript: `tail -F ~/pager/logs/<session>.log`. Service-level events: `journalctl --user -u pager.service`.

## Inventory + SSH

`pager ssh <alias>` reads `inventory.yaml`. Schema:

```yaml
hosts:
  <alias>:
    host: <ip-or-dns>           # required
    user: <username>            # default: current user
    port: <port>                # default: 22
    key: <path-to-priv-key>     # preferred path
    password_env: VAR_NAME      # fallback; VAR_NAME's value lives in ~/pager/.env
    tags: [free, form, labels]  # optional
```

Inventory parsing is done by an inline Python+pyyaml block in `cmd_ssh` inside `bin/pager`. Missing host or wrong field → clear error, non-zero exit.

**Pattern for adding a password-auth host**: add the export line to `~/pager/.env` (`export FOO_SSH_PASS="…"`), then reference it as `password_env: FOO_SSH_PASS` in `inventory.yaml`. Never put the literal password in the YAML.

## Actions

`pager run <alias> <action> [-- args]` streams `actions/<action>.sh` over SSH via `bash -s -- "$@"`. Args after `--` become `$1`..`$N` on the remote.

When writing a new action:
- It runs on the **remote** host, not this one.
- It can't see local files or local env beyond what's passed via args.
- For multi-host orchestration, loop over aliases at the caller level — `pager run` itself is single-host.

## Where new things go

| Adding… | Goes in |
|---|---|
| Helper subcommand | Add a `cmd_<verb>` function in `bin/pager` and a case entry at the dispatch block. Update `cmd_help` so it shows up. |
| Remote action | `actions/<verb>.sh`, runs on remote via `bash -s`. |
| New host | `hosts:` entry in `inventory.yaml`. |
| Secret | Append `export NAME="…"` to `~/pager/.env`, document the var in `.env.example`. |
| Always-on background service | New `~/.config/systemd/user/<name>.service` (template it like `systemd/pager.service`), `systemctl --user enable --now`. |

## What's intentionally NOT here

- **No remote reachability layer** (Tailscale / Cloudflare tunnel / port forward). Not needed for the primary mobile flow — Claude Code's `--remote-control` relays through claude.ai. Only relevant for the alt SSH-from-phone path, which is the user's responsibility to wire up.
- **No multi-user / multi-host orchestration framework** (Ansible, Salt). Single-user, single-control-plane, simple shell glue.
- **No secret encryption beyond file perms.** `~/pager/.env` is chmod 600. If a future user wants per-secret encryption (`gpg`, `age`, `pass`), add a wrapper script — don't change the .env format.
- **No external repo dependencies.** Everything pager needs is in this repo. Companion repos (e.g. a hardware-setup repo) may exist on a particular user's box but pager must work without them.

## How to resume work

1. Read this file (just did).
2. Skim `README.md` for the current command surface.
3. `pager status` + `systemctl --user status pager.service` to confirm baseline.
4. If something's off, the logs are at `~/pager/logs/` and `journalctl --user -u pager.service`.
